use poseidon::poseidon2;

mod merkle_tree;

fn main(
    // Public inputs (4)
    root: pub Field,
    collateral_nullifier_hash: pub Field,
    // keccak256 of the action context (recipient, relayer, fee, amount, chain, vault...) reduced mod p.
    // Computed by the contract; binding it here means nobody can change those values after the proof is made.
    ext_data_hash: pub Field,
    yield_index: pub Field,

    // Private inputs
    nullifier: Field,
    secret: Field,
    merkle_proof: [Field; 20],
    is_even: [bool; 20],
) {
    // compute the commitment as nested hash: Poseidon2(Poseidon2(nullifier, secret), yield_index)
    let inner: Field = poseidon2::Poseidon2::hash([nullifier, secret], 2);
    let commitment: Field = poseidon2::Poseidon2::hash([inner, yield_index], 2);

    // check that the collateral nullifier hash matches: Poseidon2(nullifier, 1)
    assert(poseidon2::Poseidon2::hash([nullifier, 1], 2) == collateral_nullifier_hash);

    // tie ext_data_hash into the constraint system (a no-op square, as in Tornado Cash)
    let ext_sq = ext_data_hash * ext_data_hash;
    assert(ext_sq == ext_data_hash * ext_data_hash);

    // check that the commitment is in the Merkle tree
    let computed_root: Field = merkle_tree::compute_merkle_root(commitment, merkle_proof, is_even);
    assert(computed_root == root);
}
