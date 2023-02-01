# 
# pact.py
# 
# Author(s):
# Philip Wiese <wiesep@student.ethz.ch>
# 
# Copyright (c) 2023 ETH Zurich.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# 

from torch import nn

import quantlib.editing.lightweight as qlw
import quantlib.editing.lightweight.rules as qlr
from quantlib.editing.lightweight.rules.filters import NameFilter
from quantlib.editing.fx.passes.pact import HarmonizePACTNetPass, PACTTracer, PACT_symbolic_trace
from quantlib.editing.fx.passes.pact import WrapModulePass
from quantlib.editing.fx.passes.pact import ApproximateGELUPass, ApproximateSoftmaxPass, CanonicalizeLayerNormPass, AnnotateEpsPass

from quantlib.algorithms.pact.pact_ops import *
from quantlib.algorithms.pact.pact_controllers import *
from quantlib.algorithms.pact.dynamic_precision import *

from systems.CIFAR10.ICCT.model.transformer import Attention

from systems.CIFAR10.utils.transforms.transforms import CIFAR10STATS
_CIFAR10_EPS = CIFAR10STATS['quantize']['eps']

def pact_recipe(net : nn.Module,
                config : dict):

    # config is expected to contain 3 keys for each layer type:
    # PACTConv2d, PACTLinear, PACTUnsignedAct
    # their values are dicts with keys that will be used as NameFilter
    # arguments containing the kwargs for each layer.
    # An additional dict is expected to be stored under the key "kwargs", which
    # is used as the default kwargs.
    # Under the key "harmonize", the configuration for the harmonization pass
    # should be stored.

    rhos = []
    conv_cfg = config["PACTConv2d"]
    lin_cfg = config["PACTLinear"]
    act_cfg = config["PACTUnsignedAct"]

    harmonize_cfg = config["harmonize"]


    def make_rules(cfg : dict,
                   rule : type):
        rules = []
        default_cfg = cfg["kwargs"] if "kwargs" in cfg.keys() else {}
        layer_keys = [k for k in cfg.keys() if k != "kwargs" and k != "dynamic"]
        for k in layer_keys:
            filt = NameFilter(k)
            kwargs = default_cfg.copy()
            kwargs.update(cfg[k])
            rho = rule(filt, **kwargs)
            rules.append(rho)
        return rules

    rhos += make_rules(conv_cfg,
                       qlr.pact.ReplaceConvLinearPACTRule)
    rhos += make_rules(lin_cfg,
                       qlr.pact.ReplaceConvLinearPACTRule)
    rhos += make_rules(act_cfg,
                       qlr.pact.ReplaceActPACTRule)

    # ICCT = set([Attention])
    # PACTTracer = LeafTracer(leaf_types=list(PACT_OPS_INCLUSIVE | ICCT))
    # mhsa_tracer = partial(custom_symbolic_trace, tracer=PACTTracer)

    # def ICCT_MHSA():
    #     return Attention(dim=64, heads=4, dim_head=64)
    # wrap_mhsa_pass = WrapModulePass(Attention, ICCT_MHSA)

    # net = mhsa_tracer(net)
    # net = wrap_mhsa_pass(net)

    lwg = qlw.LightweightGraph(net)
    lwe = qlw.LightweightEditor(lwg)

    print("[QuantLab] === Original Network ===")
    lwg.show_nodes_list()

    lwe.startup()
    for rho in rhos:
        lwe.set_lwr(rho)
        lwe.apply()
    lwe.shutdown()

    net = lwg.net

    approximate_gelu_pass = ApproximateGELUPass()
    approximate_softmax_pass = ApproximateSoftmaxPass()
    canonicalize_layernorm_pass = CanonicalizeLayerNormPass()
    harmonize_pass = HarmonizePACTNetPass(**harmonize_cfg)

    
    net = PACT_symbolic_trace(net)
    net = approximate_gelu_pass(net)
    net = approximate_softmax_pass(net)
    net = harmonize_pass(net)
    net = canonicalize_layernorm_pass(net)
    
    lwg = qlw.LightweightGraph(net)

    print("[QuantLab] === PACT Network ===")
    lwg.show_nodes_list()

    return net

def get_pact_controllers(net : nn.Module, schedules : dict, kwargs_linear : dict = {}, kwargs_activation : dict = {}, dynamic : dict = {}):
    lin_modules = PACTLinearController.get_modules(net)
    act_modules = PACTActController.get_modules(net)
    intadd_modules = PACTIntegerModulesController.get_modules(net)
    eps_modules = PACTEpsController.get_modules(net)
    
    annotate_eps_pass = AnnotateEpsPass(eps_in=_CIFAR10_EPS, prop_eps=True, prop_n_levels = True, prop_sign = True,  verbose=False)
    eps_ctrl = PACTEpsController(net, eps_modules, schedules["eps"], PACTTracer,annotate_eps_pass)
    lin_ctrl = PACTLinearController(lin_modules, schedules["linear"], **kwargs_linear)
    act_ctrl = PACTActController(act_modules, schedules["activation"], **kwargs_activation)
    intadd_ctrl = PACTIntegerModulesController(intadd_modules)

    return lin_ctrl, act_ctrl, intadd_ctrl, eps_ctrl
    # return lin_ctrl, act_ctrl, intadd_ctrl
