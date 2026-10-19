// Generates a real UltraHonk proof with the same libraries the frontend uses (noir_js + bb.js).
// Used by test/RealProof.t.sol through vm.ffi. Run `npm install` in the repo root first.
//
//   npx tsx js-scripts/prove.ts <withdraw|borrow> <nullifier> <secret> <yieldIndex> <extDataHash> <leaf0> <leaf1> ...
//
// Prints abi.encode(bytes proof, bytes32[] publicInputs) as 0x-hex on stdout.
import { Barretenberg, UltraHonkBackend } from "@aztec/bb.js";
// @ts-ignore
import { Noir } from "@noir-lang/noir_js";
import { encodeAbiParameters, type Hex } from "viem";
import fs from "fs";
import path from "path";
import { merkleTree } from "./merkleTree.js";

const CIRCUITS = {
  withdraw: "../../circuits/target/circuits.json",
  borrow: "../../circuits_borrow/target/circuits_borrow.json",
} as const;

function toBytes32(hex: string): Uint8Array {
  const h = BigInt(hex).toString(16).padStart(64, "0");
  return Uint8Array.from(h.match(/../g)!.map((b) => parseInt(b, 16)));
}
const toHex = (b: Uint8Array): Hex => ("0x" + Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")) as Hex;

async function main() {
  const [kind, nullifierHex, secretHex, yieldIndexHex, extDataHash, ...leaves] = process.argv.slice(2);
  if (kind !== "withdraw" && kind !== "borrow") throw new Error("first argument must be withdraw or borrow");
  const circuit = JSON.parse(fs.readFileSync(path.resolve(__dirname, CIRCUITS[kind]), "utf8"));

  const bb = await Barretenberg.new();
  const nullifier = toBytes32(nullifierHex);
  const secret = toBytes32(secretHex);
  const yieldIndex = toBytes32(yieldIndexHex);
  const one = toBytes32("0x1");

  const { hash: nullifierHash } = await bb.poseidon2Hash({ inputs: [nullifier] });
  const { hash: collateralHash } = await bb.poseidon2Hash({ inputs: [nullifier, one] });
  const { hash: inner } = await bb.poseidon2Hash({ inputs: [nullifier, secret] });
  const { hash: commitment } = await bb.poseidon2Hash({ inputs: [inner, yieldIndex] });

  const tree = await merkleTree(leaves);
  const index = tree.getIndex(toHex(commitment));
  if (index < 0) throw new Error("commitment not found among the leaves");
  const mp = tree.proof(index);

  const common = {
    root: mp.root,
    collateral_nullifier_hash: toHex(collateralHash),
    ext_data_hash: extDataHash,
    yield_index: toHex(yieldIndex),
    nullifier: toHex(nullifier),
    secret: toHex(secret),
    merkle_proof: mp.pathElements.map((x: string) => x.toString()),
    is_even: mp.pathIndices.map((i: number) => i % 2 == 0),
  };
  const input = kind === "withdraw" ? { ...common, nullifier_hash: toHex(nullifierHash) } : common;

  const { witness } = await new Noir(circuit).execute(input);
  const log = console.log;
  console.log = () => {};
  const { proof, publicInputs } = await new UltraHonkBackend(circuit.bytecode, bb).generateProof(witness, {
    verifierTarget: "evm",
  });
  console.log = log;

  process.stdout.write(
    encodeAbiParameters([{ type: "bytes" }, { type: "bytes32[]" }], [toHex(proof), publicInputs as Hex[]]),
  );
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
