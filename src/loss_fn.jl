## Loss function
struct LossLikelihood end
function (::LossLikelihood)(data, pred, rng)
    if any(pred .<= 0.) # we do not tolerate non-positive ICs -
        return Inf
    elseif size(data) != size(pred) # preventing Zygote to crash
        return Inf
    end

    l = sum((log.(data) .- log.(pred)).^2)

    if l isa Number # preventing any other reason for Zygote to crash
        return l
    else 
        return Inf
    end
end

(l::LossLikelihood)(data, pred) = l(data, pred, nothing) # method required for loss_u0_prior in InferenceProblem

struct LossLikelihoodPartialObs end
function (::LossLikelihoodPartialObs)(data, pred, rng)
    # this happens for initial conditions
    size(data, 1) == 3 ? data = data[2:3,:] : nothing
    # we discard prediction of the resource abundance
    pred = pred[2:end,:]
    if any(pred .<= 0.) # we do not tolerate non-positive ICs -
        return Inf
    elseif size(data,2) != size(pred, 2) # preventing Zygote to crash
        println("hey")
        @show size(data)
        @show size(pred)
        return Inf
    end

    l = sum((log.(data) .- log.(pred)).^2)

    if l isa Number # preventing any other reason for Zygote to crash
        return l
    else 
        return Inf
    end
end

(l::LossLikelihoodPartialObs)(data, pred) = l(data, pred, nothing) # method required for loss_u0_prior in InferenceProblem
