function make_selectors_from_cliques(cliques, n)
    selector_mats = [spzeros(length(cliques[i]), n) for i in 1:length(cliques)]
    for i in 1:length(cliques)
        idx = 1
        for node in cliques[i]
            selector_mats[i][idx, node] = 1.0
            idx += 1
        end
    end
    return selector_mats
end


# TODO: make this multithreaded
function make_selectors_from_clique_graph(cg::CliqueGraph, n)
    m = length(cg.active_cliques)
    selector_mats = Vector{SparseMatrixCSC}(undef, m)
    for (i, cnum) in enumerate(cg.active_cliques)
        clique = cg.membership_mat[:,cnum]
        selector_mat = spzeros(sum(clique), n)

        idx = 1
        for node in findnz(clique)[1]
            selector_mat[idx, node] = 1.0
            idx += 1
        end
        selector_mats[i] = selector_mat
    end
    return selector_mats
end


function get_selectors(input_mat::SparseMatrixCSC; verbose=true, ret_cliques=true)
    n = size(input_mat)[1]
    preprocess!(input_mat)

    sp = sparsity_pattern(input_mat)
    # TODO: make this work for matrices that are block diagonal (under reordering)
    if is_separable(sp)
        error(ArgumentError("Input matrix should not be block diagonal; decompose the blocks separately."))
    end

    # L is the chordal extension of sp under reordering perm
    perm, iperm, L = get_chordal_extension(sp; verbose=verbose)

    cliques = get_cliques(L)
    cg = generate_clique_graph(cliques, n)
    merge_cliques!(cg; verbose=verbose)

    if ret_cliques
        Cls = get_cliques(cg)
        Tls = make_selectors_from_cliques(Cls, n)
        return perm, iperm, Tls, Cls
    end

    Tls = make_selectors_from_clique_graph(cg, n)
    return perm, iperm, Tls
end
