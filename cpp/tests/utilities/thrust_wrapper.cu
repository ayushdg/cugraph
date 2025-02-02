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

#include <utilities/thrust_wrapper.hpp>

#include <raft/handle.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/copy.h>
#include <thrust/sort.h>

namespace cugraph {
namespace test {

template <typename vertex_t, typename value_t>
rmm::device_uvector<value_t> sort_by_key(raft::handle_t const& handle,
                                         vertex_t const* keys,
                                         value_t const* values,
                                         size_t num_pairs)
{
  rmm::device_uvector<vertex_t> sorted_keys(num_pairs, handle.get_stream_view());
  rmm::device_uvector<value_t> sorted_values(num_pairs, handle.get_stream_view());

  thrust::copy(
    rmm::exec_policy(handle.get_stream_view()), keys, keys + num_pairs, sorted_keys.begin());
  thrust::copy(
    rmm::exec_policy(handle.get_stream_view()), values, values + num_pairs, sorted_values.begin());

  thrust::sort_by_key(rmm::exec_policy(handle.get_stream_view()),
                      sorted_keys.begin(),
                      sorted_keys.end(),
                      sorted_values.begin());

  return sorted_values;
}

template rmm::device_uvector<float> sort_by_key<int32_t, float>(raft::handle_t const& handle,
                                                                int32_t const* keys,
                                                                float const* values,
                                                                size_t num_pairs);

template rmm::device_uvector<double> sort_by_key<int32_t, double>(raft::handle_t const& handle,
                                                                  int32_t const* keys,
                                                                  double const* values,
                                                                  size_t num_pairs);

template rmm::device_uvector<int32_t> sort_by_key<int32_t, int32_t>(raft::handle_t const& handle,
                                                                    int32_t const* keys,
                                                                    int32_t const* values,
                                                                    size_t num_pairs);

template rmm::device_uvector<float> sort_by_key<int64_t, float>(raft::handle_t const& handle,
                                                                int64_t const* keys,
                                                                float const* values,
                                                                size_t num_pairs);

template rmm::device_uvector<double> sort_by_key<int64_t, double>(raft::handle_t const& handle,
                                                                  int64_t const* keys,
                                                                  double const* values,
                                                                  size_t num_pairs);

template rmm::device_uvector<int64_t> sort_by_key<int64_t, int64_t>(raft::handle_t const& handle,
                                                                    int64_t const* keys,
                                                                    int64_t const* values,
                                                                    size_t num_pairs);

}  // namespace test
}  // namespace cugraph
