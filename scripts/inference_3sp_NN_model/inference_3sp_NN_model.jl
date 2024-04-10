# Refactored code for running multiple inference simulations
cd(@__DIR__)
using JLD2, DataFrames, Random, Dates, ProgressMeter, Distributed, ComponentArrays
include("../../src/utils.jl")
include("../../src/run_simulations.jl")

const SimulFile = "simul_model_selec.jl"
const Epochs = [5000]
const SimpleParameters = ComponentArray(H = Float32[1.24, 2.5],
                            q = Float32[4.98, 0.8],
                            r = Float32[1.0, -0.4, -0.08],
                            K₁₁ = Float32[1.0],
                            A = Float32[1.0])
const TrueInitialState = Float32[0.77, 0.060, 0.945]
const TimeSteps = range(500f0, step=4, length=100)
const TimeSpan = (0f0, TimeSteps[end])
const ss = exp.(range(log(8e-1), log(100e-1), length = 5))
const loss_likelihood = LossLikelihood()

Random.seed!(5)

function generate_model_params()
    return (alg = Tsit5(),
            abstol = 1e-4,
            reltol = 1e-4,
            tspan = TimeSpan,
            saveat = TimeSteps,
            verbose = false,
            maxiters = 50_000)
end

function generate_inference_params()
    return (tsteps = TimeSteps,
            optimizers = [ADAM(5e-3)],
            verbose_loss = true,
            info_per_its = 1000,
            multi_threading = false)
end

function generate_date(ss)
    data_arr = []
    p_trues = []
    model_params = generate_model_params()
    model = WaterDepEM(ModelParams(; u0=TrueInitialState, model_params...))
    for s in ss
        ps = ComponentArray(SimpleParameters; s = [s])
        data = simulate(model, p = ps ) |> Array
        push!(data_arr, data)
        push!(p_trues, ps)
    end
    data_arr, p_trues
end

function generate_df_results()
    DataFrame(group_size = Int[], 
            noise = Float64[], 
            loss = Float64[], 
            time = Float64[], 
            res = Any[], 
            adtype = Any[],
            s = Float64[],
            model = String[],
            )
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

function initialize_params_and_constraints(model::HybridEcosystemModel)
    p_true = model.mp.p
    T = eltype(p_true)
    distrib_param_arr = Pair{Symbol, Any}[]

    for dp in keys(p_true)
        pair = dp => Product([Uniform(sort(T[0.25 * k, 1.75 * k])...) for k in p_true[dp]])
        push!(distrib_param_arr, pair)
    end
    pair_r = :r => Product([Uniform(sort(T[0.25 * k, 1.75 * k])...) for k in p_true.r[2:end]])
    pair_nn = :p_nn => Uniform(-Inf, Inf)
    append!(distrib_param_arr, [pair_r, pair_nn])


    distrib_param = NamedTuple(distrib_param_arr)
    p_bij = NamedTuple([dp => bijector(distrib_param[dp]) for dp in keys(distrib_param)])
    u0_bij = bijector(Uniform(T(1e-3), T(5e0)))  # For initial conditions
    p_init = NamedTuple([k => rand(distrib_param[k]) for k in keys(distrib_param)])
    p_nn, _ = Lux.setup(rng, neural_net)
    p_init = merge(p_init, (;p_nn))

    return ComponentArray(p_init), p_bij, u0_bij
end

function create_simulation_parameters(data_arr, p_trues)
    group_sizes = [9]
    noises = 0.1:0.1:0.3
    nruns = 10
    adtypes = [Optimization.AutoZygote()]

    pars_arr = Dict{Symbol,Any}[]
    for group_size in group_sizes, noise in noises, run in 1:nruns, adtype in adtypes, d in 1:length(data_arr)
        sensealg = typeof(adtype) <: AutoZygote ? BacksolveAdjoint(autojacvec=ReverseDiffVJP(true)) : nothing
        model_params = generate_model_params()

        u0_init = data_arr[d][:,1]
        p_true = p_trues[d]
        pref = p_true.s[1]

        # SimpleModel
        model = SimpleEcosystemModel3SP(ModelParams(; p=SimpleParameters, u0=u0_init, sensealg, model_params...))
        p_init, p_bij, u0_bij = initialize_params_and_constraints(model)
        infprob = InferenceProblem(model, p_init; 
                                    loss_u0_prior = loss_likelihood, 
                                    loss_likelihood = loss_likelihood, 
                                    p_bij, u0_bij)

        sim_params = pack_simulation_parameters(;group_size, noise, adtype, model, d, infprob, pref)
        push!(pars_arr, sim_params)

        # Hybrid model
        model = HybridEcosystemModel(ModelParams(; p=p_true, u0=u0_init, sensealg, model_params...))
        p_init, p_bij, u0_bij = initialize_params_and_constraints(model)
        infprob = InferenceProblem(model, p_init; 
                                    loss_u0_prior = loss_likelihood, 
                                    loss_likelihood = loss_likelihood, 
                                    p_bij, u0_bij)

        sim_params = pack_simulation_parameters(;group_size, noise, adtype, model, d, infprob, pref)
        push!(pars_arr, sim_params)

    end
    return pars_arr
end

setup_distributed_environment(SimulFile)
data_arr, p_trues = generate_date(ss)
simulation_parameters = create_simulation_parameters(data_arr, p_trues);

println("Warming up...")
run_simulations([simulation_parameters[1] for p in workers()], 10, data_arr) # precompilation for std model
run_simulations([simulation_parameters[2] for p in workers()], 10, data_arr) # precompilation for omniv

println("Starting simulations...")
results = run_simulations(simulation_parameters, Epochs, data_arr)
save_results(string(@__FILE__); results, data_arr, p_trues, Epochs)
