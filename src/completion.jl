
# VA Algorithm 10.2, pg 362
function maxdet_completion(A::SparseMatrixCSC{Tv, Ti}) where {Tv <: AbstractFloat, Ti <: Integer}
    !issymmetric(A) && error(ArgumentError("A must be symmetric"))
    n = size(A, 1)

    sp = sparsity_pattern(A)
    L = get_chordal_extension(sp; perm=nothing, verbose=false)[3]
    ct = CliqueTree(L)
    order_snds!(ct)

    W = Matrix(A[ct.perm, ct.perm])
    # cache = zeros(maximum(length.(ct.seps)), maximum(length.(ct.snds)))

    for j in (length(ct.snds)-1):-1:1
        vrep_ind = ct.postordering[j]
        vrep = ct.vreps[vrep_ind]

        ν = ct.snds[vrep_ind]
        α = ct.seps[vrep_ind]
        η = filter(x->(!(x in ν) && !(x in α)), vrep+1:n)

        # cache = W_αα^† * W_αν
        cache = zeros(length(α), length(ν))
        try
            cache = W[α, α] \ W[α, ν]
        catch e
            # Occasionally get a singular exception. Ignoring for now
            cache = pinv(W[α, α]) * W[α, ν]
        end

        # res = W_ηα * cache = W_ηα * W_αα^† * W_αν
        @views mul!(W[η, ν], W[η, α], cache)
        W[ν, η] .= W[η, ν]'
    end
    iperm = invperm(ct.perm)
    return W[iperm, iperm]
end


# Logarithmic Barriers for Sparse Matrix Cones
# Andersen, Dahl, Vandenberghe
# Algorithm 4.2
# NOTE: This is very inefficient -- needs some significant work
# TODO: Clean up
function maxdet_completion_etree(A::SparseMatrixCSC{Tv, Ti}) where {Tv <: AbstractFloat, Ti <: Integer}
    !issymmetric(A) && error(ArgumentError("A must be symmetric"))
    n = size(A, 1)

    sp = sparsity_pattern(A)
    L = get_chordal_extension(sp; perm=nothing, verbose=false)[3]
    et = EliminationTree(L; peo=collect(1:n))
    postordering = get_postordering(et.par, et.child)

    L_chol = spzeros(n,n)
    L_chol[diagind(L_chol)] .= 1
    D_chol = Diagonal(zeros(n))
    V = Vector{Matrix{Float64}}(undef, n)

    for i in n:-1:1
        j = postordering[i]
        Ij = rowvals(L)[nzrange(L, j)]

        Vj = (i == n) ? [A[end, end]] : V[j]
        if i != n
            try
                L_chol[Ij, j] = (-Vj) \ Vector{Float64}(A[Ij, j])
            catch e
                L_chol[Ij, j] = -pinv(Vj) * Vector{Float64}(A[Ij, j])
            end
            D_chol[j,j] = 1/(A[j,j] + dot(A[Ij, j], L_chol[Ij, j]))
        else
            D_chol[j,j] = 1 / A[j,j]
        end

        for ch in et.child[j]
            Ich = rowvals(L)[nzrange(L, ch)]

            nv = length(Ij) + 1
            tmp = zeros(nv, nv)
            tmp[1,1] = A[j,j]
            tmp[2:end, 1] .= A[Ij, j]
            tmp[1, 2:end] .= A[Ij, j]
            tmp[2:end, 2:end] .= Vj

            E_Jj_Ich = spzeros(length(Ij) + 1, length(Ich))
            Jj = vcat([j], Ij)
            for ii in 1:length(Jj), jj in 1:length(Ich)
                if Jj[ii] == Ich[jj]
                    E_Jj_Ich[ii, jj] = 1.0
                end
            end

            V[ch] = E_Jj_Ich' * tmp * E_Jj_Ich
        end
    end

    return L_chol, D_chol
end



# Logarithmic Barriers for Sparse Matrix Cones
# Andersen, Dahl, Vandenberghe
# Algorithm 7.3
# NOTE: This is very inefficient -- needs some significant work
# TODO: cleanup
function maxdet_completion_factors(A::SparseMatrixCSC{Tv, Ti}) where {Tv <: AbstractFloat, Ti <: Integer}
    !issymmetric(A) && error(ArgumentError("A must be symmetric"))
    n = size(A, 1)

    sp = sparsity_pattern(A)
    L = get_chordal_extension(sp; perm=nothing, verbose=false)[3]
    etree_par = get_etree(L)
    vreps, snd_par, snd_membership = max_supernode_etree(L, etree_par)
    n_snds = length(vreps)
    snds = [Vector{Int}(undef, 0) for _ in 1:n_snds]
    for v in 1:n
        push!(snds[snd_membership[v]], v)
    end
    snd_children = get_children_from_par(snd_par)
    post_ord = get_postordering(snd_par, snd_children)


    L_chol = spzeros(n,n)
    L_chol[diagind(L_chol)] .= 1
    D_chol = spzeros(n,n)
    V = Vector{Matrix{Float64}}(undef, n_snds)

    for i in n_snds:-1:1
        vrep_ind = post_ord[i]
        j = vreps[vrep_ind]
        Jj = vcat([j], rowvals(L)[nzrange(L, j)])
        Nj = snds[vrep_ind]
        Aj = filter(x->!(x in Nj), Jj)

        Vj = (i == n_snds) ? [A[end, end]] : V[vrep_ind]
        if i != n_snds
            try
                L_chol[Aj, Nj] = -Vj \ A[Aj, Nj]
            catch e
                L_chol[Aj, Nj] = pinv(-Vj) * A[Aj, Nj]
            end
            D_chol[Nj,Nj] = inv(Matrix(A[Nj,Nj] + A[Aj, Nj]'*L_chol[Aj, Nj]))
        else
            D_chol[Nj,Nj] = inv(Matrix(A[Nj,Nj]))
        end

        for ch_ind in snd_children[vrep_ind]
            Nch = snds[ch_ind]
            ch = vreps[ch_ind]
            Jch = vcat([ch], rowvals(L)[nzrange(L, ch)])
            Ach = filter(x->!(x in Nch), Jch)

            nv = length(Jj)
            tmp = zeros(nv, nv)
            len_Nj = length(Nj)
            len_Aj = length(Aj)
            tmp[1:len_Nj,1:len_Nj] = A[Nj,Nj]
            if len_Aj > 0
                tmp[len_Nj+1:end, 1:len_Nj] .= A[Aj, Nj]
                tmp[1:len_Nj, len_Nj+1:end] .= A[Aj, Nj]'
                tmp[len_Nj+1:end, len_Nj+1:end] .= Vj
            end
            E_Jj_Ach = spzeros(length(Jj), length(Ach))
            for ii in 1:length(Jj), jj in 1:length(Ach)
                if Jj[ii] == Ach[jj]
                    E_Jj_Ach[ii, jj] = 1.0
                end
            end
            V[ch_ind] = E_Jj_Ach' * tmp * E_Jj_Ach
        end
    end

    return L_chol, D_chol
end


# FIXME: errors on higher rank tests
function minrank_completion(A::SparseMatrixCSC{Tv, Ti}) where {Tv <: AbstractFloat, Ti <: Integer}
    !issymmetric(A) && error(ArgumentError("A must be symmetric"))
    n = size(A, 1)

    sp = sparsity_pattern(A)
    _, _, L = get_chordal_extension(sp; perm=nothing)
    etree_par = get_etree(L)
    vreps, snd_par, snd_membership = max_supernode_etree(L, etree_par)
    n_snds = length(vreps)
    snds = [Vector{Int}(undef, 0) for _ in 1:n_snds]
    for v in 1:n
        push!(snds[snd_membership[v]], v)
    end
    snd_children = get_children_from_par(snd_par)
    post_ord = get_postordering(snd_par, snd_children)

    # Determine rank
    r = maximum([rank(Matrix(A[c,c]), rtol=1e-10) for c in get_cliques(L)])

    Y = zeros(n, r)
    for j in n_snds:-1:1
        vrep_ind = post_ord[j]
        vrep = vreps[vrep_ind]

        # col_j = vcat([vrep], rowvals(L)[nzrange(L, vrep)])
        ν = snds[vrep_ind]
        α = filter(x->!(x in ν), rowvals(L)[nzrange(L, vrep)])
        col_j = vcat(ν, α)
        # @show ν, α

        dd, VV = eigen(Symmetric(Matrix(@view(A[col_j,col_j])), :L), sortby=x->-real(x))
        r_ = min(length(dd), r)
        Z = VV[:,1:r_]*Diagonal(sqrt.(max.(real.(dd[1:r_]), 0.0)))


        if j == n_snds
            Y[ν, 1:r_] .= Z[1:length(ν), :]
            continue
        end



        U = @view(Z[1:length(ν), 1:r_])
        V = @view(Z[length(ν)+1:end, 1:r_])

        W_Y, Σ_Y, Q_Y = svd(Y[α, :], full=true, alg = LinearAlgebra.QRIteration())
        W_V, Σ_V, Q_V = svd(V, full=true, alg = LinearAlgebra.QRIteration())
        svd_err = sum(abs.(Σ_Y .- Σ_V))
        # @show svd_err
        #
        # Q = Q_V*Q_Y'
        # # @show Y[α, :]
        # if !all(Y[α, :] .≈ V*Q)
        #     d = sign.((Y[α, :]*Q_Y)[1,:]) .* sign.((V*Q_V)[1,:])
        #     Q = Q_V*Diagonal(d)*Q_Y'
        # end
        # Q2, Σ, Q1 = svd(V'*Y[α, 1:r_], full=true, alg = LinearAlgebra.QRIteration())

        Q2, Σ, Q1 = svd(V'*Y[α, 1:r_], full=true)
        Q = Q2*Q1'

        # @show size(U)
        # @show size(Y[α, 1:r_])

        # S = svd(Y[α, 1:r_], U)
        # Q = S.V' * S.U
        # @show size(S.V)
        Y[ν, 1:r_] .= U*Q
        if any(abs.(A[col_j, col_j] .- Y[col_j, 1:r_]*Y[col_j, 1:r_]') .> 1e-3)
            @show col_j, ν, α
            display(Y[col_j, :])
            display(A[col_j, col_j] .- Y[col_j, 1:r_]*Y[col_j, 1:r_]')
        end
    end
    return Y
end
