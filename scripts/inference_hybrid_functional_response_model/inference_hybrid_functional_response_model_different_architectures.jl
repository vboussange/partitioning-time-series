#=
Running inference simulations with `Model3SP` and
`HybridFuncRespModel`.

Inference simulations are ran in a distributed fashion; the first argument to
the script corresponds to the number of processes used.

```
julia scripts/inference_3sp/inference_3sp.jl 10
```
will run the script over 10 processes.
=#
using JLD2
using DataFrames
using Random
using Dates
using ProgressMeter
using ComponentArrays
import OrdinaryDiffEq: Tsit5
using OptimizationOptimisers
using Distributions
using Bijectors
include("../../src/utils.jl")

# setting up the distributed computing environment
using Distributed
procs_to_add = isempty(ARGS) ? 0 : parse(Int, ARGS[1])
addprocs(procs_to_add, exeflags="--project=$(Base.active_project())")
@everywhere begin 
    using PiecewiseInference
    using SciMLSensitivity

    cd(@__DIR__)
    include("../../src/3sp_model.jl")
    include("../../src/hybrid_functional_response_model.jl")
    include("../../src/loss_fn.jl")

end

# setting up the global parameters
SYNTHETIC_DATA_PARAMS = (;p_true = ComponentArray(
                                                H = Float32[1.24, 2.5],
                                                q = Float32[4.98, 0.8],
                                                r = Float32[1.0, -0.4, -0.08],
                                                A = Float32[1.0]),
                        tsteps = range(500f0, step=4, length=100),
                        solver_params = (;alg = Tsit5(),
                                        abstol = 1e-4,
                                        reltol = 1e-4,
                                        sensealg= BacksolveAdjoint(autojacvec=ReverseDiffVJP(true)),
                                        maxiters= 50_000,
                                        verbose = false),
                        perturb = 0.5,
                        u0_true = Float32[0.77, 0.060, 0.945],)

SIMULATION_CONFIG = (;group_sizes = [5],
                    noises      = [0.1],
                    nruns       = 10,)

INFERENCE_PARAMS = (;optimizers = [OptimizationOptimisers.Adam(1e-2)],
                    verbose_loss = true,
                    info_per_its = 100,
                    multi_threading = false,
                    epochs = 5000,
                    )

function generate_data()
    true_model = Model3SP(ModelParams(; p = SYNTHETIC_DATA_PARAMS.p_true,
                                    u0=SYNTHETIC_DATA_PARAMS.u0_true, 
                                    saveat=SYNTHETIC_DATA_PARAMS.tsteps,
                                    tspan = (0.0, last(SYNTHETIC_DATA_PARAMS.tsteps)),
                                    SYNTHETIC_DATA_PARAMS.solver_params...
                                    ))
    
    synthetic_data = simulate(true_model) |> Array
    return synthetic_data
end

# Initialize parameters and setup constraints
function initialize_params_and_constraints(model)
    p_true = model.mp.p
    T = eltype(p_true)
    distrib_param_arr = []
    for dp in keys(p_true)
        pair = dp => Product([Uniform(sort(T[0.25 * k, 1.75 * k])...) for k in p_true[dp]])
        push!(distrib_param_arr, pair)
    end
    
    distrib_param = NamedTuple(distrib_param_arr)
    p_bij = NamedTuple([dp => bijector(distrib_param[dp]) for dp in keys(distrib_param)])
    u0_bij = bijector(Uniform(T(1e-3), T(5e0)))  # For initial conditions
    p_init = NamedTuple([k => rand(distrib_param[k]) for k in keys(distrib_param)])
    return ComponentArray(p_init), p_bij, u0_bij
end

function initialize_params_and_constraints_hybrid_model()
    T = eltype(SYNTHETIC_DATA_PARAMS.p_true)
    distrib_param_arr = Pair{Symbol, Any}[]

    for dp in [:r, :A]
        dp == :p_nn && continue
        pair = dp => Product([Uniform(sort(T[(1f0-SYNTHETIC_DATA_PARAMS.perturb/2f0) * k, (1f0+SYNTHETIC_DATA_PARAMS.perturb/2f0) * k])...) for k in SYNTHETIC_DATA_PARAMS.p_true[dp]])
        push!(distrib_param_arr, pair)
    end

    pair_nn = :p_nn => Uniform(-Inf, Inf)
    push!(distrib_param_arr, pair_nn)

    distrib_param = NamedTuple(distrib_param_arr)

    p_bij = NamedTuple([dp => bijector(distrib_param[dp]) for dp in keys(distrib_param)])
    u0_bij = bijector(Uniform(T(1e-3), T(5e0)))  # For initial conditions
    p_init = NamedTuple([k => rand(distrib_param[k]) for k in keys(distrib_param) if k !== :p_nn]) |> ComponentArray

    return p_init, p_bij, u0_bij
end

function create_simulation_parameters(data)
    group_sizes = SIMULATION_CONFIG.group_sizes
    noises = SIMULATION_CONFIG.noises
    nruns = SIMULATION_CONFIG.nruns
    adtype = Optimization.AutoZygote()
    u0_init = data[:,1]
    pars_arr = NamedTuple[]
    for group_size in group_sizes, noise in noises, run in 1:nruns

        noisy_data = data .* exp.(noise * randn(size(data)))


        # SimpleModel
        model = Model3SP(ModelParams(;p = SYNTHETIC_DATA_PARAMS.p_true,
                                    u0= u0_init,
                                    saveat = SYNTHETIC_DATA_PARAMS.tsteps,
                                    SYNTHETIC_DATA_PARAMS.solver_params...))
        p_init, p_bij, u0_bij = initialize_params_and_constraints(model)
        infprob = InferenceProblem(model, 
                                    p_init; 
                                    loss_u0_prior = LossLikelihood(), 
                                    loss_likelihood = LossLikelihood(), 
                                    p_bij, u0_bij)

        sim_params = (;group_size, noise, model, data = noisy_data, infprob, adtype)
        push!(pars_arr, sim_params)

        # Hybrid model 1
        p_init, p_bij, u0_bij = initialize_params_and_constraints_hybrid_model()

        model = HybridFuncRespModel(ModelParams(;p = p_init, 
                                                u0= u0_init, 
                                                saveat = SYNTHETIC_DATA_PARAMS.tsteps,
                                                SYNTHETIC_DATA_PARAMS.solver_params...),
                                                seed=run)
        infprob = InferenceProblem(model, model.mp.p; 
                                    loss_u0_prior = LossLikelihood(), 
                                    loss_likelihood = LossLikelihood(), 
                                    p_bij, u0_bij)
        sim_params = (;group_size, noise, model, data=noisy_data, infprob, adtype)
        push!(pars_arr, sim_params)

        # Hybrid model 2
        model = HybridFuncRespModel2(ModelParams(;p = p_init, 
                                                u0= u0_init, 
                                                saveat = SYNTHETIC_DATA_PARAMS.tsteps,
                                                SYNTHETIC_DATA_PARAMS.solver_params...),
                                                seed=run)
        infprob = InferenceProblem(model, model.mp.p; 
                                    loss_u0_prior = LossLikelihood(), 
                                    loss_likelihood = LossLikelihood(), 
                                    p_bij, u0_bij)
        sim_params = (;group_size, noise, model, data=noisy_data, infprob, adtype)
        push!(pars_arr, sim_params)

    end
    return pars_arr
end

data = generate_data()
simulation_parameters = create_simulation_parameters(data);

pmap_res = @showprogress pmap(1:length(simulation_parameters)) do i
    try
        # invoke garbage collection to avoid memory overshoot on SLURM
        GC.gc()
        @unpack group_size, noise, adtype, data, model, infprob, noise = simulation_parameters[i]
        println("Launching simulations for group_size = $group_size, noise = $noise")

        stats = @timed inference(infprob; group_size = group_size,
                                            data = data, 
                                            adtype, 
                                            epochs=[INFERENCE_PARAMS.epochs], 
                                            tsteps = SYNTHETIC_DATA_PARAMS.tsteps,
                                            optimizers = INFERENCE_PARAMS.optimizers,
                                            verbose_loss = INFERENCE_PARAMS.verbose_loss,
                                            info_per_its = INFERENCE_PARAMS.info_per_its,
                                            multi_threading = INFERENCE_PARAMS.multi_threading)
        res = stats.value
        l = res.losses[end]
        return true, (group_size, noise, l, stats.time, res, typeof(adtype), name(model))

    catch e
        println("error with", pars_arr[i])
        println(e)
        (false, nothing)
    end
end

df_results = DataFrame(group_size = Int[], 
                        noise = Float64[], 
                        loss = Float64[], 
                        time = Float64[], 
                        res = Any[], 
                        adtype = Any[],
                        model = String[],
                        )

for (st, row) in pmap_res
    if st 
        push!(df_results, row)
    end
end

save_results(string(@__FILE__); results=df_results, data, SYNTHETIC_DATA_PARAMS...)
