/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
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

#include <experimental/detail/graph_utils.cuh>
#include <experimental/graph.hpp>
#include <experimental/graph_functions.hpp>
#include <experimental/graph_view.hpp>
#include <patterns/copy_to_adj_matrix_row_col.cuh>
#include <utilities/error.hpp>
#include <utilities/shuffle_comm.cuh>

#include <rmm/thrust_rmm_allocator.h>
#include <raft/handle.hpp>
#include <rmm/device_uvector.hpp>

#include <thrust/copy.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/scan.h>
#include <thrust/sort.h>
#include <thrust/tuple.h>

#include <algorithm>
#include <iterator>
#include <numeric>
#include <tuple>
#include <utility>

namespace cugraph {
namespace experimental {
namespace detail {

template <typename vertex_t, typename edge_t, typename weight_t>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>>
  compressed_sparse_to_edgelist(edge_t const *compressed_sparse_offsets,
                                vertex_t const *compressed_sparse_indices,
                                weight_t const *compressed_sparse_weights,
                                vertex_t major_first,
                                vertex_t major_last,
                                bool is_weighted,
                                cudaStream_t stream)
{
  edge_t number_of_edges{0};
  raft::update_host(
    &number_of_edges, compressed_sparse_offsets + (major_last - major_first), 1, stream);
  CUDA_TRY(cudaStreamSynchronize(stream));
  rmm::device_uvector<vertex_t> edgelist_major_vertices(number_of_edges, stream);
  rmm::device_uvector<vertex_t> edgelist_minor_vertices(number_of_edges, stream);
  rmm::device_uvector<weight_t> edgelist_weights(is_weighted ? number_of_edges : 0, stream);

  // FIXME: this is highly inefficient for very high-degree vertices, for better performance, we can
  // fill high-degree vertices using one CUDA block per vertex, mid-degree vertices using one CUDA
  // warp per vertex, and low-degree vertices using one CUDA thread per block
  thrust::for_each(rmm::exec_policy(stream)->on(stream),
                   thrust::make_counting_iterator(major_first),
                   thrust::make_counting_iterator(major_last),
                   [compressed_sparse_offsets,
                    major_first,
                    p_majors = edgelist_major_vertices.begin()] __device__(auto v) {
                     auto first = compressed_sparse_offsets[v - major_first];
                     auto last  = compressed_sparse_offsets[v - major_first + 1];
                     thrust::fill(thrust::seq, p_majors + first, p_majors + last, v);
                   });
  thrust::copy(rmm::exec_policy(stream)->on(stream),
               compressed_sparse_indices,
               compressed_sparse_indices + number_of_edges,
               edgelist_minor_vertices.begin());
  if (is_weighted) {
    thrust::copy(rmm::exec_policy(stream)->on(stream),
                 compressed_sparse_weights,
                 compressed_sparse_weights + number_of_edges,
                 edgelist_weights.data());
  }

  return std::make_tuple(std::move(edgelist_major_vertices),
                         std::move(edgelist_minor_vertices),
                         std::move(edgelist_weights));
}

template <typename vertex_t, typename edge_t, typename weight_t>
edge_t groupby_e_and_coarsen_edgelist(vertex_t *edgelist_major_vertices /* [INOUT] */,
                                      vertex_t *edgelist_minor_vertices /* [INOUT] */,
                                      weight_t *edgelist_weights /* [INOUT] */,
                                      edge_t number_of_edges,
                                      bool is_weighted,
                                      cudaStream_t stream)
{
  auto pair_first =
    thrust::make_zip_iterator(thrust::make_tuple(edgelist_major_vertices, edgelist_minor_vertices));

  if (is_weighted) {
    thrust::sort_by_key(rmm::exec_policy(stream)->on(stream),
                        pair_first,
                        pair_first + number_of_edges,
                        edgelist_weights);

    rmm::device_uvector<vertex_t> tmp_edgelist_major_vertices(number_of_edges, stream);
    rmm::device_uvector<vertex_t> tmp_edgelist_minor_vertices(tmp_edgelist_major_vertices.size(),
                                                              stream);
    rmm::device_uvector<weight_t> tmp_edgelist_weights(tmp_edgelist_major_vertices.size(), stream);
    auto it = thrust::reduce_by_key(
      rmm::exec_policy(stream)->on(stream),
      pair_first,
      pair_first + number_of_edges,
      edgelist_weights,
      thrust::make_zip_iterator(thrust::make_tuple(tmp_edgelist_major_vertices.begin(),
                                                   tmp_edgelist_minor_vertices.begin())),
      tmp_edgelist_weights.begin());
    auto ret =
      static_cast<edge_t>(thrust::distance(tmp_edgelist_weights.begin(), thrust::get<1>(it)));

    auto edge_first =
      thrust::make_zip_iterator(thrust::make_tuple(tmp_edgelist_major_vertices.begin(),
                                                   tmp_edgelist_minor_vertices.begin(),
                                                   tmp_edgelist_weights.begin()));
    thrust::copy(rmm::exec_policy(stream)->on(stream),
                 edge_first,
                 edge_first + ret,
                 thrust::make_zip_iterator(thrust::make_tuple(
                   edgelist_major_vertices, edgelist_minor_vertices, edgelist_weights)));

    return ret;
  } else {
    thrust::sort(rmm::exec_policy(stream)->on(stream), pair_first, pair_first + number_of_edges);
    return static_cast<edge_t>(thrust::distance(
      pair_first,
      thrust::unique(
        rmm::exec_policy(stream)->on(stream), pair_first, pair_first + number_of_edges)));
  }
}

template <typename vertex_t, typename edge_t, typename weight_t>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>>
  compressed_sparse_to_relabeled_and_grouped_and_coarsened_edgelist(
    edge_t const *compressed_sparse_offsets,
    vertex_t const *compressed_sparse_indices,
    weight_t const *compressed_sparse_weights,
    vertex_t const *p_major_labels,
    vertex_t const *p_minor_labels,
    vertex_t major_first,
    vertex_t major_last,
    vertex_t minor_first,
    vertex_t minor_last,
    bool is_weighted,
    cudaStream_t stream)
{
  // FIXME: it might be possible to directly create relabled & coarsened edgelist from the
  // compressed sparse format to save memory

  rmm::device_uvector<vertex_t> edgelist_major_vertices(0, stream);
  rmm::device_uvector<vertex_t> edgelist_minor_vertices(0, stream);
  rmm::device_uvector<weight_t> edgelist_weights(0, stream);
  std::tie(edgelist_major_vertices, edgelist_minor_vertices, edgelist_weights) =
    compressed_sparse_to_edgelist(compressed_sparse_offsets,
                                  compressed_sparse_indices,
                                  compressed_sparse_weights,
                                  major_first,
                                  major_last,
                                  is_weighted,
                                  stream);

  auto pair_first = thrust::make_zip_iterator(
    thrust::make_tuple(edgelist_major_vertices.begin(), edgelist_minor_vertices.begin()));
  thrust::transform(
    rmm::exec_policy(stream)->on(stream),
    pair_first,
    pair_first + edgelist_major_vertices.size(),
    pair_first,
    [p_major_labels, p_minor_labels, major_first, minor_first] __device__(auto val) {
      return thrust::make_tuple(p_major_labels[thrust::get<0>(val) - major_first],
                                p_minor_labels[thrust::get<1>(val) - minor_first]);
    });

  auto number_of_edges =
    groupby_e_and_coarsen_edgelist(edgelist_major_vertices.data(),
                                   edgelist_minor_vertices.data(),
                                   edgelist_weights.data(),
                                   static_cast<edge_t>(edgelist_major_vertices.size()),
                                   is_weighted,
                                   stream);
  edgelist_major_vertices.resize(number_of_edges, stream);
  edgelist_major_vertices.shrink_to_fit(stream);
  edgelist_minor_vertices.resize(number_of_edges, stream);
  edgelist_minor_vertices.shrink_to_fit(stream);
  if (is_weighted) {
    edgelist_weights.resize(number_of_edges, stream);
    edgelist_weights.shrink_to_fit(stream);
  }

  return std::make_tuple(std::move(edgelist_major_vertices),
                         std::move(edgelist_minor_vertices),
                         std::move(edgelist_weights));
}

// multi-GPU version
template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::enable_if_t<
  multi_gpu,
  std::tuple<std::unique_ptr<graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>,
             rmm::device_uvector<vertex_t>>>
coarsen_graph(
  raft::handle_t const &handle,
  graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu> const &graph_view,
  vertex_t const *labels,
  bool do_expensive_check)
{
  auto &comm               = handle.get_comms();
  auto const comm_size     = comm.get_size();
  auto const comm_rank     = comm.get_rank();
  auto &row_comm           = handle.get_subcomm(cugraph::partition_2d::key_naming_t().row_name());
  auto const row_comm_size = row_comm.get_size();
  auto const row_comm_rank = row_comm.get_rank();
  auto &col_comm           = handle.get_subcomm(cugraph::partition_2d::key_naming_t().col_name());
  auto const col_comm_size = col_comm.get_size();
  auto const col_comm_rank = col_comm.get_rank();

  if (do_expensive_check) {
    // currently, nothing to do
  }

  // 1. construct coarsened edge list

  rmm::device_uvector<vertex_t> adj_matrix_minor_labels(
    store_transposed ? graph_view.get_number_of_local_adj_matrix_partition_rows()
                     : graph_view.get_number_of_local_adj_matrix_partition_cols(),
    handle.get_stream());
  if (store_transposed) {
    copy_to_adj_matrix_row(handle, graph_view, labels, adj_matrix_minor_labels.data());
  } else {
    copy_to_adj_matrix_col(handle, graph_view, labels, adj_matrix_minor_labels.data());
  }

  std::vector<rmm::device_uvector<vertex_t>> coarsened_edgelist_major_vertices{};
  std::vector<rmm::device_uvector<vertex_t>> coarsened_edgelist_minor_vertices{};
  std::vector<rmm::device_uvector<weight_t>> coarsened_edgelist_weights{};
  coarsened_edgelist_major_vertices.reserve(graph_view.get_number_of_local_adj_matrix_partitions());
  coarsened_edgelist_minor_vertices.reserve(coarsened_edgelist_major_vertices.size());
  coarsened_edgelist_weights.reserve(
    graph_view.is_weighted() ? coarsened_edgelist_major_vertices.size() : size_t{0});
  for (size_t i = 0; i < graph_view.get_number_of_local_adj_matrix_partitions(); ++i) {
    coarsened_edgelist_major_vertices.emplace_back(0, handle.get_stream());
    coarsened_edgelist_minor_vertices.emplace_back(0, handle.get_stream());
    if (graph_view.is_weighted()) {
      coarsened_edgelist_weights.emplace_back(0, handle.get_stream());
    }
  }
  // FIXME: we may compare performance/memory footprint with the hash_based approach especially when
  // cuco::dynamic_map becomes available (so we don't need to preallocate memory assuming the worst
  // case). We may be able to limit the memory requirement close to the final coarsened edgelist
  // with the hash based approach.
  for (size_t i = 0; i < graph_view.get_number_of_local_adj_matrix_partitions(); ++i) {
    // 1-1. locally construct coarsened edge list

    rmm::device_uvector<vertex_t> major_labels(
      store_transposed ? graph_view.get_number_of_local_adj_matrix_partition_cols(i)
                       : graph_view.get_number_of_local_adj_matrix_partition_rows(i),
      handle.get_stream());
    // FIXME: this copy is unnecessary, beter fix RAFT comm's bcast to take const iterators for
    // input
    thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                 labels,
                 labels + major_labels.size(),
                 major_labels.begin());
    device_bcast(col_comm,
                 major_labels.data(),
                 major_labels.data(),
                 major_labels.size(),
                 static_cast<int>(i),
                 handle.get_stream());

    rmm::device_uvector<vertex_t> edgelist_major_vertices(0, handle.get_stream());
    rmm::device_uvector<vertex_t> edgelist_minor_vertices(0, handle.get_stream());
    rmm::device_uvector<weight_t> edgelist_weights(0, handle.get_stream());
    std::tie(edgelist_major_vertices, edgelist_minor_vertices, edgelist_weights) =
      compressed_sparse_to_relabeled_and_grouped_and_coarsened_edgelist(
        graph_view.offsets(i),
        graph_view.indices(i),
        graph_view.weights(i),
        major_labels.data(),
        adj_matrix_minor_labels.data(),
        store_transposed ? graph_view.get_local_adj_matrix_partition_col_first(i)
                         : graph_view.get_local_adj_matrix_partition_row_first(i),
        store_transposed ? graph_view.get_local_adj_matrix_partition_col_last(i)
                         : graph_view.get_local_adj_matrix_partition_row_last(i),
        store_transposed ? graph_view.get_local_adj_matrix_partition_row_first(i)
                         : graph_view.get_local_adj_matrix_partition_col_first(i),
        store_transposed ? graph_view.get_local_adj_matrix_partition_row_last(i)
                         : graph_view.get_local_adj_matrix_partition_col_last(i),
        graph_view.is_weighted(),
        handle.get_stream());

    // 1-2. globaly shuffle

    {
      rmm::device_uvector<vertex_t> rx_edgelist_major_vertices(0, handle.get_stream());
      rmm::device_uvector<vertex_t> rx_edgelist_minor_vertices(0, handle.get_stream());
      rmm::device_uvector<weight_t> rx_edgelist_weights(0, handle.get_stream());
      if (graph_view.is_weighted()) {
        auto edge_first =
          thrust::make_zip_iterator(thrust::make_tuple(edgelist_major_vertices.begin(),
                                                       edgelist_minor_vertices.begin(),
                                                       edgelist_weights.begin()));
        std::forward_as_tuple(
          std::tie(rx_edgelist_major_vertices, rx_edgelist_minor_vertices, rx_edgelist_weights),
          std::ignore) =
          groupby_gpuid_and_shuffle_values(
            handle.get_comms(),
            edge_first,
            edge_first + edgelist_major_vertices.size(),
            [key_func =
               detail::compute_gpu_id_from_edge_t<vertex_t>{
                 comm_size, row_comm_size, col_comm_size}] __device__(auto val) {
              return key_func(thrust::get<0>(val), thrust::get<1>(val));
            },
            handle.get_stream());
      } else {
        auto edge_first = thrust::make_zip_iterator(
          thrust::make_tuple(edgelist_major_vertices.begin(), edgelist_minor_vertices.begin()));
        std::forward_as_tuple(std::tie(rx_edgelist_major_vertices, rx_edgelist_minor_vertices),
                              std::ignore) =
          groupby_gpuid_and_shuffle_values(
            handle.get_comms(),
            edge_first,
            edge_first + edgelist_major_vertices.size(),
            [key_func =
               detail::compute_gpu_id_from_edge_t<vertex_t>{
                 comm_size, row_comm_size, col_comm_size}] __device__(auto val) {
              return key_func(thrust::get<0>(val), thrust::get<1>(val));
            },
            handle.get_stream());
      }

      edgelist_major_vertices = std::move(rx_edgelist_major_vertices);
      edgelist_minor_vertices = std::move(rx_edgelist_minor_vertices);
      edgelist_weights        = std::move(rx_edgelist_weights);
    }

    // 1-3. append data to local adjacency matrix partitions

    // FIXME: we can skip this if groupby_gpuid_and_shuffle_values is updated to return sorted edge
    // list based on the final matrix partition (maybe add
    // groupby_adj_matrix_partition_and_shuffle_values).

    auto local_partition_id_op =
      [comm_size,
       key_func = detail::compute_partition_id_from_edge_t<vertex_t>{
         comm_size, row_comm_size, col_comm_size}] __device__(auto pair) {
        return key_func(thrust::get<0>(pair), thrust::get<1>(pair)) /
               comm_size;  // global partition id to local partition id
      };
    auto pair_first = thrust::make_zip_iterator(
      thrust::make_tuple(edgelist_major_vertices.begin(), edgelist_minor_vertices.begin()));
    auto counts = graph_view.is_weighted()
                    ? groupby_and_count(pair_first,
                                        pair_first + edgelist_major_vertices.size(),
                                        edgelist_weights.begin(),
                                        local_partition_id_op,
                                        graph_view.get_number_of_local_adj_matrix_partitions(),
                                        handle.get_stream())
                    : groupby_and_count(pair_first,
                                        pair_first + edgelist_major_vertices.size(),
                                        local_partition_id_op,
                                        graph_view.get_number_of_local_adj_matrix_partitions(),
                                        handle.get_stream());

    std::vector<size_t> h_counts(counts.size());
    raft::update_host(h_counts.data(), counts.data(), counts.size(), handle.get_stream());
    handle.get_stream_view().synchronize();

    std::vector<size_t> h_displacements(h_counts.size(), size_t{0});
    std::partial_sum(h_counts.begin(), h_counts.end() - 1, h_displacements.begin() + 1);

    for (int j = 0; j < col_comm_size; ++j) {
      auto number_of_partition_edges = groupby_e_and_coarsen_edgelist(
        edgelist_major_vertices.begin() + h_displacements[j],
        edgelist_minor_vertices.begin() + h_displacements[j],
        graph_view.is_weighted() ? edgelist_weights.begin() + h_displacements[j]
                                 : static_cast<weight_t *>(nullptr),
        h_counts[j],
        graph_view.is_weighted(),
        handle.get_stream());

      auto cur_size = coarsened_edgelist_major_vertices[j].size();
      // FIXME: this can lead to frequent costly reallocation; we may be able to avoid this if we
      // can reserve address space to avoid expensive reallocation.
      // https://devblogs.nvidia.com/introducing-low-level-gpu-virtual-memory-management
      coarsened_edgelist_major_vertices[j].resize(cur_size + number_of_partition_edges,
                                                  handle.get_stream());
      coarsened_edgelist_minor_vertices[j].resize(coarsened_edgelist_major_vertices[j].size(),
                                                  handle.get_stream());
      if (graph_view.is_weighted()) {
        coarsened_edgelist_weights[j].resize(coarsened_edgelist_major_vertices[j].size(),
                                             handle.get_stream());

        auto src_edge_first =
          thrust::make_zip_iterator(thrust::make_tuple(edgelist_major_vertices.begin(),
                                                       edgelist_minor_vertices.begin(),
                                                       edgelist_weights.begin())) +
          h_displacements[j];
        auto dst_edge_first =
          thrust::make_zip_iterator(thrust::make_tuple(coarsened_edgelist_major_vertices[j].begin(),
                                                       coarsened_edgelist_minor_vertices[j].begin(),
                                                       coarsened_edgelist_weights[j].begin())) +
          cur_size;
        thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                     src_edge_first,
                     src_edge_first + number_of_partition_edges,
                     dst_edge_first);
      } else {
        auto src_edge_first = thrust::make_zip_iterator(thrust::make_tuple(
                                edgelist_major_vertices.begin(), edgelist_minor_vertices.begin())) +
                              h_displacements[j];
        auto dst_edge_first = thrust::make_zip_iterator(
                                thrust::make_tuple(coarsened_edgelist_major_vertices[j].begin(),
                                                   coarsened_edgelist_minor_vertices[j].begin())) +
                              cur_size;
        thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                     src_edge_first,
                     src_edge_first + edgelist_major_vertices.size(),
                     dst_edge_first);
      }
    }
  }

  for (size_t i = 0; i < coarsened_edgelist_major_vertices.size(); ++i) {
    auto number_of_partition_edges = groupby_e_and_coarsen_edgelist(
      coarsened_edgelist_major_vertices[i].data(),
      coarsened_edgelist_minor_vertices[i].data(),
      graph_view.is_weighted() ? coarsened_edgelist_weights[i].data()
                               : static_cast<weight_t *>(nullptr),
      static_cast<edge_t>(coarsened_edgelist_major_vertices[i].size()),
      graph_view.is_weighted(),
      handle.get_stream());
    coarsened_edgelist_major_vertices[i].resize(number_of_partition_edges, handle.get_stream());
    coarsened_edgelist_major_vertices[i].shrink_to_fit(handle.get_stream());
    coarsened_edgelist_minor_vertices[i].resize(number_of_partition_edges, handle.get_stream());
    coarsened_edgelist_minor_vertices[i].shrink_to_fit(handle.get_stream());
    if (coarsened_edgelist_weights.size() > 0) {
      coarsened_edgelist_weights[i].resize(number_of_partition_edges, handle.get_stream());
      coarsened_edgelist_weights[i].shrink_to_fit(handle.get_stream());
    }
  }

  // 3. find unique labels for this GPU

  rmm::device_uvector<vertex_t> unique_labels(graph_view.get_number_of_local_vertices(),
                                              handle.get_stream());
  thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
               labels,
               labels + unique_labels.size(),
               unique_labels.begin());
  thrust::sort(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
               unique_labels.begin(),
               unique_labels.end());
  unique_labels.resize(
    thrust::distance(unique_labels.begin(),
                     thrust::unique(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                    unique_labels.begin(),
                                    unique_labels.end())),
    handle.get_stream());

  rmm::device_uvector<vertex_t> rx_unique_labels(0, handle.get_stream());
  std::tie(rx_unique_labels, std::ignore) = groupby_gpuid_and_shuffle_values(
    handle.get_comms(),
    unique_labels.begin(),
    unique_labels.end(),
    [key_func = detail::compute_gpu_id_from_vertex_t<vertex_t>{comm.get_size()}] __device__(
      auto val) { return key_func(val); },
    handle.get_stream());

  unique_labels = std::move(rx_unique_labels);

  thrust::sort(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
               unique_labels.begin(),
               unique_labels.end());
  unique_labels.resize(
    thrust::distance(unique_labels.begin(),
                     thrust::unique(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                    unique_labels.begin(),
                                    unique_labels.end())),
    handle.get_stream());

  // 4. renumber

  rmm::device_uvector<vertex_t> renumber_map_labels(0, handle.get_stream());
  partition_t<vertex_t> partition(std::vector<vertex_t>(comm_size + 1, 0),
                                  row_comm_size,
                                  col_comm_size,
                                  row_comm_rank,
                                  col_comm_rank);
  vertex_t number_of_vertices{};
  edge_t number_of_edges{};
  {
    std::vector<vertex_t *> major_ptrs(coarsened_edgelist_major_vertices.size());
    std::vector<vertex_t *> minor_ptrs(major_ptrs.size());
    std::vector<edge_t> counts(major_ptrs.size());
    for (size_t i = 0; i < coarsened_edgelist_major_vertices.size(); ++i) {
      major_ptrs[i] = coarsened_edgelist_major_vertices[i].data();
      minor_ptrs[i] = coarsened_edgelist_minor_vertices[i].data();
      counts[i]     = static_cast<edge_t>(coarsened_edgelist_major_vertices[i].size());
    }
    std::tie(renumber_map_labels, partition, number_of_vertices, number_of_edges) =
      renumber_edgelist<vertex_t, edge_t, multi_gpu>(handle,
                                                     unique_labels.data(),
                                                     static_cast<vertex_t>(unique_labels.size()),
                                                     major_ptrs,
                                                     minor_ptrs,
                                                     counts,
                                                     do_expensive_check);
  }

  // 5. build a graph

  std::vector<edgelist_t<vertex_t, edge_t, weight_t>> edgelists{};
  edgelists.resize(graph_view.get_number_of_local_adj_matrix_partitions());
  for (size_t i = 0; i < edgelists.size(); ++i) {
    edgelists[i].p_src_vertices = store_transposed ? coarsened_edgelist_minor_vertices[i].data()
                                                   : coarsened_edgelist_major_vertices[i].data();
    edgelists[i].p_dst_vertices = store_transposed ? coarsened_edgelist_major_vertices[i].data()
                                                   : coarsened_edgelist_minor_vertices[i].data();
    edgelists[i].p_edge_weights = graph_view.is_weighted() ? coarsened_edgelist_weights[i].data()
                                                           : static_cast<weight_t *>(nullptr);
    edgelists[i].number_of_edges = static_cast<edge_t>(coarsened_edgelist_major_vertices[i].size());
  }

  return std::make_tuple(
    std::make_unique<graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>(
      handle,
      edgelists,
      partition,
      number_of_vertices,
      number_of_edges,
      graph_properties_t{graph_view.is_symmetric(), false, graph_view.is_weighted()},
      true),
    std::move(renumber_map_labels));
}

// single-GPU version
template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::enable_if_t<
  !multi_gpu,
  std::tuple<std::unique_ptr<graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>,
             rmm::device_uvector<vertex_t>>>
coarsen_graph(
  raft::handle_t const &handle,
  graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu> const &graph_view,
  vertex_t const *labels,
  bool do_expensive_check)
{
  if (do_expensive_check) {
    // currently, nothing to do
  }

  rmm::device_uvector<vertex_t> coarsened_edgelist_major_vertices(0, handle.get_stream());
  rmm::device_uvector<vertex_t> coarsened_edgelist_minor_vertices(0, handle.get_stream());
  rmm::device_uvector<weight_t> coarsened_edgelist_weights(0, handle.get_stream());
  std::tie(coarsened_edgelist_major_vertices,
           coarsened_edgelist_minor_vertices,
           coarsened_edgelist_weights) =
    compressed_sparse_to_relabeled_and_grouped_and_coarsened_edgelist(
      graph_view.offsets(),
      graph_view.indices(),
      graph_view.weights(),
      labels,
      labels,
      vertex_t{0},
      graph_view.get_number_of_vertices(),
      vertex_t{0},
      graph_view.get_number_of_vertices(),
      graph_view.is_weighted(),
      handle.get_stream());

  rmm::device_uvector<vertex_t> unique_labels(graph_view.get_number_of_vertices(),
                                              handle.get_stream());
  thrust::copy(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
               labels,
               labels + unique_labels.size(),
               unique_labels.begin());
  thrust::sort(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
               unique_labels.begin(),
               unique_labels.end());
  unique_labels.resize(
    thrust::distance(unique_labels.begin(),
                     thrust::unique(rmm::exec_policy(handle.get_stream())->on(handle.get_stream()),
                                    unique_labels.begin(),
                                    unique_labels.end())),
    handle.get_stream());

  auto renumber_map_labels = renumber_edgelist<vertex_t, edge_t, multi_gpu>(
    handle,
    unique_labels.data(),
    static_cast<vertex_t>(unique_labels.size()),
    coarsened_edgelist_major_vertices.data(),
    coarsened_edgelist_minor_vertices.data(),
    static_cast<edge_t>(coarsened_edgelist_major_vertices.size()),
    do_expensive_check);

  edgelist_t<vertex_t, edge_t, weight_t> edgelist{};
  edgelist.p_src_vertices = store_transposed ? coarsened_edgelist_minor_vertices.data()
                                             : coarsened_edgelist_major_vertices.data();
  edgelist.p_dst_vertices = store_transposed ? coarsened_edgelist_major_vertices.data()
                                             : coarsened_edgelist_minor_vertices.data();
  edgelist.p_edge_weights  = coarsened_edgelist_weights.data();
  edgelist.number_of_edges = static_cast<edge_t>(coarsened_edgelist_major_vertices.size());

  return std::make_tuple(
    std::make_unique<graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>(
      handle,
      edgelist,
      static_cast<vertex_t>(renumber_map_labels.size()),
      graph_properties_t{graph_view.is_symmetric(), false, graph_view.is_weighted()},
      true),
    std::move(renumber_map_labels));
}

}  // namespace detail

template <typename vertex_t,
          typename edge_t,
          typename weight_t,
          bool store_transposed,
          bool multi_gpu>
std::tuple<std::unique_ptr<graph_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu>>,
           rmm::device_uvector<vertex_t>>
coarsen_graph(
  raft::handle_t const &handle,
  graph_view_t<vertex_t, edge_t, weight_t, store_transposed, multi_gpu> const &graph_view,
  vertex_t const *labels,
  bool do_expensive_check)
{
  return detail::coarsen_graph(handle, graph_view, labels, do_expensive_check);
}

// explicit instantiation

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, float, true, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, float, true, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, float, false, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, float, false, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, float, true, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, float, true, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, float, false, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, float, false, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, float, true, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, float, true, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, float, false, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, float, false, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, float, true, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, float, true, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, float, false, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, float, false, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, float, true, true>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, float, true, true> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, float, false, true>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, float, false, true> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, float, true, false>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, float, true, false> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, float, false, false>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, float, false, false> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, double, true, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, double, true, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, double, false, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, double, false, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, double, true, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, double, true, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int32_t, double, false, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int32_t, double, false, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, double, true, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, double, true, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, double, false, true>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, double, false, true> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, double, true, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, double, true, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int32_t, int64_t, double, false, false>>,
                    rmm::device_uvector<int32_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int32_t, int64_t, double, false, false> const &graph_view,
              int32_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, double, true, true>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, double, true, true> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, double, false, true>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, double, false, true> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, double, true, false>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, double, true, false> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

template std::tuple<std::unique_ptr<graph_t<int64_t, int64_t, double, false, false>>,
                    rmm::device_uvector<int64_t>>
coarsen_graph(raft::handle_t const &handle,
              graph_view_t<int64_t, int64_t, double, false, false> const &graph_view,
              int64_t const *labels,
              bool do_expensive_check);

}  // namespace experimental
}  // namespace cugraph
