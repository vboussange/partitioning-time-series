#=
5 species model.
=#
using SparseArrays
using ComponentArrays

struct Model5SP{MP,II,JJ} <: AbstractODEModel
    mp::MP
    I::II
    J::JJ
end

function Model5SP(mp)
    ## FOODWEB
    foodweb = DiGraph(5)
    add_edge!(foodweb, 2 => 1) # C1 to R1
    add_edge!(foodweb, 5 => 4) # C2 to R2
    add_edge!(foodweb, 3 => 2) # P to C1
    add_edge!(foodweb, 3 => 5) # P to C2

    I, J, _ = findnz(adjacency_matrix(foodweb))

    Model5SP(mp, I, J)
end

function (model::Model5SP)(du, u, p, t)
    @unpack r = p
    T = eltype(u)
    ũ = max.(u, zero(T))

    F = feeding(model, ũ, p, t)
    Aarr = competition(model, ũ, p, t)

    feed_pred_gains = (F .- F') * ũ
    du .= ũ .*(r .- Aarr .+ feed_pred_gains)
end

function competition(::Model5SP, u, p, t)
    @unpack A = p
    T = eltype(A)
    Au = vcat(A[1] * u[1], zeros(T,2), A[2] * u[4], zero(T))
    return Au
end

function feeding(model::Model5SP, u, p, t)
    @unpack I, J = model
    @unpack ω, H, q = p

    # creating foodweb
    OT = eltype(ω)
    Warr = sparse(I, J, vcat(one(OT), ω, one(OT) .- ω, one(OT)), 5, 5)

    # handling time
    Harr = sparse(I, J, H, 5, 5)

    # attack rates
    qarr = sparse(I, J, q, 5, 5)

    return qarr .* Warr ./ (one(eltype(u)) .+ qarr .* Harr .* (Warr * u))
end

function get_metadata(::Model3SP)
    species_colors = ["tab:red", "tab:green", "tab:blue", "tab:orange", "tab:purple"]
    node_labels = ["R1", 
                    "C1", 
                    "P1", 
                    "R2", 
                    "C2"]

    pos = Dict(0 => [0, 0], 1 => [1, 1], 2 => [2, 2], 3 => [4, 0], 4 => [3, 1],)
    return (; species_colors, node_labels, pos)
end

