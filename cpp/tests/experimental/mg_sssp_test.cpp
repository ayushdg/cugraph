/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <utilities/base_fixture.hpp>
#include <utilities/test_utilities.hpp>
#include <utilities/thrust_wrapper.hpp>

#include <algorithms.hpp>
#include <experimental/graph.hpp>
#include <experimental/graph_functions.hpp>
#include <experimental/graph_view.hpp>
#include <partition_manager.hpp>

#include <raft/comms/comms.hpp>
#include <raft/comms/mpi_comms.hpp>
#include <raft/handle.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/device_uvector.hpp>

#include <gtest/gtest.h>

#include <random>

typedef struct SSSP_Usecase_t {
  cugraph::test::input_graph_specifier_t input_graph_specifier{};

  size_t source{0};
  bool check_correctness{false};

  SSSP_Usecase_t(std::string const& graph_file_path, size_t source, bool check_correctness = true)
    : source(source), check_correctness(check_correctness)
  {
    std::string graph_file_full_path{};
    if ((graph_file_path.length() > 0) && (graph_file_path[0] != '/')) {
      graph_file_full_path = cugraph::test::get_rapids_dataset_root_dir() + "/" + graph_file_path;
    } else {
      graph_file_full_path = graph_file_path;
    }
    input_graph_specifier.tag = cugraph::test::input_graph_specifier_t::MATRIX_MARKET_FILE_PATH;
    input_graph_specifier.graph_file_full_path = graph_file_full_path;
  };

  SSSP_Usecase_t(cugraph::test::rmat_params_t rmat_params,
                 size_t source,
                 bool check_correctness = true)
    : source(source), check_correctness(check_correctness)
  {
    input_graph_specifier.tag         = cugraph::test::input_graph_specifier_t::RMAT_PARAMS;
    input_graph_specifier.rmat_params = rmat_params;
  }
} SSSP_Usecase;

template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<cugraph::experimental::graph_t<vertex_t, edge_t, weight_t, false, multi_gpu>,
           rmm::device_uvector<vertex_t>>
read_graph(raft::handle_t const& handle, SSSP_Usecase const& configuration, bool renumber)
{
  auto& comm           = handle.get_comms();
  auto const comm_size = comm.get_size();
  auto const comm_rank = comm.get_rank();

  std::vector<size_t> partition_ids(multi_gpu ? size_t{1} : static_cast<size_t>(comm_size));
  std::iota(partition_ids.begin(),
            partition_ids.end(),
            multi_gpu ? static_cast<size_t>(comm_rank) : size_t{0});

  return configuration.input_graph_specifier.tag ==
             cugraph::test::input_graph_specifier_t::MATRIX_MARKET_FILE_PATH
           ? cugraph::test::
               read_graph_from_matrix_market_file<vertex_t, edge_t, weight_t, false, multi_gpu>(
                 handle, configuration.input_graph_specifier.graph_file_full_path, true, renumber)
           : cugraph::test::
               generate_graph_from_rmat_params<vertex_t, edge_t, weight_t, false, multi_gpu>(
                 handle,
                 configuration.input_graph_specifier.rmat_params.scale,
                 configuration.input_graph_specifier.rmat_params.edge_factor,
                 configuration.input_graph_specifier.rmat_params.a,
                 configuration.input_graph_specifier.rmat_params.b,
                 configuration.input_graph_specifier.rmat_params.c,
                 configuration.input_graph_specifier.rmat_params.seed,
                 configuration.input_graph_specifier.rmat_params.undirected,
                 configuration.input_graph_specifier.rmat_params.scramble_vertex_ids,
                 true,
                 renumber,
                 partition_ids,
                 static_cast<size_t>(comm_size));
}

class Tests_MGSSSP : public ::testing::TestWithParam<SSSP_Usecase> {
 public:
  Tests_MGSSSP() {}
  static void SetupTestCase() {}
  static void TearDownTestCase() {}

  virtual void SetUp() {}
  virtual void TearDown() {}

  // Compare the results of running SSSP on multiple GPUs to that of a single-GPU run
  template <typename vertex_t, typename edge_t, typename weight_t>
  void run_current_test(SSSP_Usecase const& configuration)
  {
    // 1. initialize handle

    raft::handle_t handle{};

    raft::comms::initialize_mpi_comms(&handle, MPI_COMM_WORLD);
    auto& comm           = handle.get_comms();
    auto const comm_size = comm.get_size();
    auto const comm_rank = comm.get_rank();

    auto row_comm_size = static_cast<int>(sqrt(static_cast<double>(comm_size)));
    while (comm_size % row_comm_size != 0) { --row_comm_size; }
    cugraph::partition_2d::subcomm_factory_t<cugraph::partition_2d::key_naming_t, vertex_t>
      subcomm_factory(handle, row_comm_size);

    // 2. create MG graph

    cugraph::experimental::graph_t<vertex_t, edge_t, weight_t, false, true> mg_graph(handle);
    rmm::device_uvector<vertex_t> d_mg_renumber_map_labels(0, handle.get_stream());
    std::tie(mg_graph, d_mg_renumber_map_labels) =
      read_graph<vertex_t, edge_t, weight_t, true>(handle, configuration, true);

    auto mg_graph_view = mg_graph.view();

    ASSERT_TRUE(static_cast<vertex_t>(configuration.source) >= 0 &&
                static_cast<vertex_t>(configuration.source) <
                  mg_graph_view.get_number_of_vertices())
      << "Invalid starting source.";

    // 3. run MG SSSP

    rmm::device_uvector<weight_t> d_mg_distances(mg_graph_view.get_number_of_local_vertices(),
                                                 handle.get_stream());
    rmm::device_uvector<vertex_t> d_mg_predecessors(mg_graph_view.get_number_of_local_vertices(),
                                                    handle.get_stream());

    CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement

    // FIXME: disable do_expensive_check
    cugraph::experimental::sssp(handle,
                                mg_graph_view,
                                d_mg_distances.data(),
                                d_mg_predecessors.data(),
                                static_cast<vertex_t>(configuration.source),
                                std::numeric_limits<weight_t>::max(),
                                true);

    CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement

    // 5. copmare SG & MG results

    if (configuration.check_correctness) {
      // 5-1. create SG graph

      cugraph::experimental::graph_t<vertex_t, edge_t, weight_t, false, false> sg_graph(handle);
      std::tie(sg_graph, std::ignore) =
        read_graph<vertex_t, edge_t, weight_t, false>(handle, configuration, false);

      auto sg_graph_view = sg_graph.view();

      std::vector<vertex_t> vertex_partition_lasts(comm_size);
      for (size_t i = 0; i < vertex_partition_lasts.size(); ++i) {
        vertex_partition_lasts[i] = mg_graph_view.get_vertex_partition_last(i);
      }

      rmm::device_scalar<vertex_t> d_source(static_cast<vertex_t>(configuration.source),
                                            handle.get_stream());
      cugraph::experimental::unrenumber_int_vertices<vertex_t, true>(
        handle,
        d_source.data(),
        size_t{1},
        d_mg_renumber_map_labels.data(),
        mg_graph_view.get_local_vertex_first(),
        mg_graph_view.get_local_vertex_last(),
        vertex_partition_lasts,
        true);
      auto unrenumbered_source = d_source.value(handle.get_stream());

      // 5-2. run SG SSSP

      rmm::device_uvector<weight_t> d_sg_distances(sg_graph_view.get_number_of_local_vertices(),
                                                   handle.get_stream());
      rmm::device_uvector<vertex_t> d_sg_predecessors(sg_graph_view.get_number_of_local_vertices(),
                                                      handle.get_stream());

      // FIXME: disable do_expensive_check
      cugraph::experimental::sssp(handle,
                                  sg_graph_view,
                                  d_sg_distances.data(),
                                  d_sg_predecessors.data(),
                                  unrenumbered_source,
                                  std::numeric_limits<weight_t>::max(),
                                  true);

      // 5-3. compare

      std::vector<edge_t> h_sg_offsets(sg_graph_view.get_number_of_vertices() + 1);
      std::vector<vertex_t> h_sg_indices(sg_graph_view.get_number_of_edges());
      std::vector<weight_t> h_sg_weights(sg_graph_view.get_number_of_edges());
      raft::update_host(h_sg_offsets.data(),
                        sg_graph_view.offsets(),
                        sg_graph_view.get_number_of_vertices() + 1,
                        handle.get_stream());
      raft::update_host(h_sg_indices.data(),
                        sg_graph_view.indices(),
                        sg_graph_view.get_number_of_edges(),
                        handle.get_stream());
      raft::update_host(h_sg_weights.data(),
                        sg_graph_view.weights(),
                        sg_graph_view.get_number_of_edges(),
                        handle.get_stream());

      std::vector<weight_t> h_sg_distances(sg_graph_view.get_number_of_vertices());
      std::vector<vertex_t> h_sg_predecessors(sg_graph_view.get_number_of_vertices());
      raft::update_host(
        h_sg_distances.data(), d_sg_distances.data(), d_sg_distances.size(), handle.get_stream());
      raft::update_host(h_sg_predecessors.data(),
                        d_sg_predecessors.data(),
                        d_sg_predecessors.size(),
                        handle.get_stream());

      std::vector<weight_t> h_mg_distances(mg_graph_view.get_number_of_local_vertices());
      std::vector<vertex_t> h_mg_predecessors(mg_graph_view.get_number_of_local_vertices());
      raft::update_host(
        h_mg_distances.data(), d_mg_distances.data(), d_mg_distances.size(), handle.get_stream());
      cugraph::experimental::unrenumber_int_vertices<vertex_t, true>(
        handle,
        d_mg_predecessors.data(),
        d_mg_predecessors.size(),
        d_mg_renumber_map_labels.data(),
        mg_graph_view.get_local_vertex_first(),
        mg_graph_view.get_local_vertex_last(),
        vertex_partition_lasts,
        true);
      raft::update_host(h_mg_predecessors.data(),
                        d_mg_predecessors.data(),
                        d_mg_predecessors.size(),
                        handle.get_stream());

      std::vector<vertex_t> h_mg_renumber_map_labels(d_mg_renumber_map_labels.size());
      raft::update_host(h_mg_renumber_map_labels.data(),
                        d_mg_renumber_map_labels.data(),
                        d_mg_renumber_map_labels.size(),
                        handle.get_stream());

      handle.get_stream_view().synchronize();

      auto max_weight_element = std::max_element(h_sg_weights.begin(), h_sg_weights.end());
      auto epsilon            = *max_weight_element * weight_t{1e-6};
      auto nearly_equal = [epsilon](auto lhs, auto rhs) { return std::fabs(lhs - rhs) < epsilon; };

      for (vertex_t i = 0; i < mg_graph_view.get_number_of_local_vertices(); ++i) {
        auto mapped_vertex = h_mg_renumber_map_labels[i];
        ASSERT_TRUE(nearly_equal(h_mg_distances[i], h_sg_distances[mapped_vertex]))
          << "MG SSSP distance for vertex: " << mapped_vertex << " in rank: " << comm_rank
          << " has value: " << h_mg_distances[i]
          << " different from the corresponding SG value: " << h_sg_distances[mapped_vertex];
        if (h_mg_predecessors[i] == cugraph::invalid_vertex_id<vertex_t>::value) {
          ASSERT_TRUE(h_sg_predecessors[mapped_vertex] == h_mg_predecessors[i])
            << "vertex reachability does not match with the SG result.";
        } else {
          auto pred_distance = h_sg_distances[h_mg_predecessors[i]];
          bool found{false};
          for (auto j = h_sg_offsets[h_mg_predecessors[i]];
               j < h_sg_offsets[h_mg_predecessors[i] + 1];
               ++j) {
            if (h_sg_indices[j] == mapped_vertex) {
              if (nearly_equal(pred_distance + h_sg_weights[j], h_sg_distances[mapped_vertex])) {
                found = true;
                break;
              }
            }
          }
          ASSERT_TRUE(found)
            << "no edge from the predecessor vertex to this vertex with the matching weight.";
        }
      }
    }
  }
};

TEST_P(Tests_MGSSSP, CheckInt32Int32Float)
{
  run_current_test<int32_t, int32_t, float>(GetParam());
}

INSTANTIATE_TEST_CASE_P(
  simple_test,
  Tests_MGSSSP,
  ::testing::Values(
    // enable correctness checks
    SSSP_Usecase("test/datasets/karate.mtx", 0),
    SSSP_Usecase("test/datasets/dblp.mtx", 0),
    SSSP_Usecase("test/datasets/wiki2003.mtx", 1000),
    SSSP_Usecase(cugraph::test::rmat_params_t{10, 16, 0.57, 0.19, 0.19, 0, false, false}, 0),
    // disable correctness checks for large graphs
    SSSP_Usecase(cugraph::test::rmat_params_t{20, 32, 0.57, 0.19, 0.19, 0, false, false},
                 0,
                 false)));

CUGRAPH_MG_TEST_PROGRAM_MAIN()
