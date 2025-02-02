# Copyright (c) 2021, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import pytest
import numpy as np

from cugraph.tests.dask.mg_context import MGContext, skip_if_not_enough_devices
from cugraph.dask.common.mg_utils import is_single_gpu
from cugraph.tests import utils

# Get parameters from standard betwenness_centrality_test
from cugraph.tests.test_betweenness_centrality import (
    DIRECTED_GRAPH_OPTIONS,
    ENDPOINTS_OPTIONS,
    NORMALIZED_OPTIONS,
    DEFAULT_EPSILON,
    SUBSET_SIZE_OPTIONS,
    SUBSET_SEED_OPTIONS,
)

from cugraph.tests.test_betweenness_centrality import (
    prepare_test,
    calc_betweenness_centrality,
    compare_scores,
)

# =============================================================================
# Parameters
# =============================================================================
DATASETS = [utils.DATASETS_UNDIRECTED[0]]
MG_DEVICE_COUNT_OPTIONS = [pytest.param(1, marks=pytest.mark.preset_gpu_count),
                           pytest.param(2, marks=pytest.mark.preset_gpu_count),
                           pytest.param(3, marks=pytest.mark.preset_gpu_count),
                           pytest.param(4, marks=pytest.mark.preset_gpu_count),
                           None]
RESULT_DTYPE_OPTIONS = [np.float64]


# FIXME: The following creates and destroys Comms at every call making the
# testsuite quite slow
@pytest.mark.skipif(
    is_single_gpu(), reason="skipping MG testing on Single GPU system"
)
@pytest.mark.parametrize("graph_file", DATASETS)
@pytest.mark.parametrize("directed", DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize("subset_size", SUBSET_SIZE_OPTIONS)
@pytest.mark.parametrize("normalized", NORMALIZED_OPTIONS)
@pytest.mark.parametrize("weight", [None])
@pytest.mark.parametrize("endpoints", ENDPOINTS_OPTIONS)
@pytest.mark.parametrize("subset_seed", SUBSET_SEED_OPTIONS)
@pytest.mark.parametrize("result_dtype", RESULT_DTYPE_OPTIONS)
@pytest.mark.parametrize("mg_device_count", MG_DEVICE_COUNT_OPTIONS)
def test_mg_betweenness_centrality(
    graph_file,
    directed,
    subset_size,
    normalized,
    weight,
    endpoints,
    subset_seed,
    result_dtype,
    mg_device_count,
):
    prepare_test()
    skip_if_not_enough_devices(mg_device_count)
    with MGContext(number_of_devices=mg_device_count,
                   p2p=True):
        sorted_df = calc_betweenness_centrality(
            graph_file,
            directed=directed,
            normalized=normalized,
            k=subset_size,
            weight=weight,
            endpoints=endpoints,
            seed=subset_seed,
            result_dtype=result_dtype,
            multi_gpu_batch=True,
        )
    compare_scores(
        sorted_df,
        first_key="cu_bc",
        second_key="ref_bc",
        epsilon=DEFAULT_EPSILON,
    )
