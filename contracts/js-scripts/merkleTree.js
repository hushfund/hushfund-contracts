import { Barretenberg } from '@aztec/bb.js';

function hexToBytes(hex) {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  const bytes = new Uint8Array(32);
  const offset = 32 - h.length / 2;
  for (let i = 0; i < h.length; i += 2) {
    bytes[offset + i / 2] = parseInt(h.substring(i, i + 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes) {
  return '0x' + Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function hashLeftRight(left, right) {
  const bb = await Barretenberg.new();
  const a = hexToBytes(left);
  const b = hexToBytes(right);
  const { hash } = await bb.poseidon2Hash({ inputs: [a, b] });
  return bytesToHex(hash);
}

export class PoseidonTree {
  constructor(levels, zeros) {
    if (zeros.length < levels + 1) {
      throw new Error("Not enough zero values provided for the given tree height.");
    }
    this.levels = levels;
    this.hashLeftRight = hashLeftRight;
    this.storage = new Map();
    this.zeros = zeros;
    this.totalLeaves = 0;
  }

  async init(defaultLeaves = []) {
    if (defaultLeaves.length > 0) {
      this.totalLeaves = defaultLeaves.length;

      defaultLeaves.forEach((leaf, index) => {
        this.storage.set(PoseidonTree.indexToKey(0, index), leaf);
      });

      for (let level = 1; level <= this.levels; level++) {
        const numNodes = Math.ceil(this.totalLeaves / (2 ** level));
        for (let i = 0; i < numNodes; i++) {
          const left = this.storage.get(PoseidonTree.indexToKey(level - 1, 2 * i)) || this.zeros[level - 1];
          const right = this.storage.get(PoseidonTree.indexToKey(level - 1, 2 * i + 1)) || this.zeros[level - 1];
          const node = await this.hashLeftRight(left, right);
          this.storage.set(PoseidonTree.indexToKey(level, i), node);
        }
      }
    }
  }

  static indexToKey(level, index) {
    return `${level}-${index}`;
  }

  getIndex(leaf) {
    for (const [key, value] of this.storage.entries()) {
      if (value === leaf && key.startsWith('0-')) {
        return parseInt(key.split('-')[1]);
      }
    }
    return -1;
  }

  root() {
    return this.storage.get(PoseidonTree.indexToKey(this.levels, 0)) || this.zeros[this.levels];
  }

  proof(index) {
    const leaf = this.storage.get(PoseidonTree.indexToKey(0, index));
    if (!leaf) throw new Error("leaf not found");

    const pathElements = [];
    const pathIndices = [];

    this.traverse(index, (level, currentIndex, siblingIndex) => {
      const sibling = this.storage.get(PoseidonTree.indexToKey(level, siblingIndex)) || this.zeros[level];
      pathElements.push(sibling);
      pathIndices.push(currentIndex % 2);
    });

    return {
      root: this.root(),
      pathElements,
      pathIndices,
      leaf,
    };
  }

  async insert(leaf) {
    const index = this.totalLeaves;
    await this.update(index, leaf, true);
    this.totalLeaves++;
  }

  async update(index, newLeaf, isInsert = false) {
    if (!isInsert && index >= this.totalLeaves) {
      throw Error("Use insert method for new elements.");
    } else if (isInsert && index < this.totalLeaves) {
      throw Error("Use update method for existing elements.");
    }

    const keyValueToStore = [];
    let currentElement = newLeaf;

    await this.traverseAsync(index, async (level, currentIndex, siblingIndex) => {
      const sibling = this.storage.get(PoseidonTree.indexToKey(level, siblingIndex)) || this.zeros[level];
      const [left, right] = currentIndex % 2 === 0 ? [currentElement, sibling] : [sibling, currentElement];
      keyValueToStore.push({ key: PoseidonTree.indexToKey(level, currentIndex), value: currentElement });
      currentElement = await this.hashLeftRight(left, right);
    });

    keyValueToStore.push({ key: PoseidonTree.indexToKey(this.levels, 0), value: currentElement });
    keyValueToStore.forEach(({ key, value }) => this.storage.set(key, value));
  }

  traverse(index, fn) {
    let currentIndex = index;
    for (let level = 0; level < this.levels; level++) {
      const siblingIndex = currentIndex % 2 === 0 ? currentIndex + 1 : currentIndex - 1;
      fn(level, currentIndex, siblingIndex);
      currentIndex = Math.floor(currentIndex / 2);
    }
  }

  async traverseAsync(index, fn) {
    let currentIndex = index;
    for (let level = 0; level < this.levels; level++) {
      const siblingIndex = currentIndex % 2 === 0 ? currentIndex + 1 : currentIndex - 1;
      await fn(level, currentIndex, siblingIndex);
      currentIndex = Math.floor(currentIndex / 2);
    }
  }
}

const ZERO_VALUES = [
  "0x2b0df951ef3a8bf2a23ac5acc4f59acca38c21ca13cbb63d412a8da53f58823b",
  "0x0a1cc9dbf552c542379dee34a6616bd37fec1b0962c4fbe314a01cffac8308c3",
  "0x0a6110e905ebe9c8a2a439acd710643468b9f51122440aadf091a4b6f167dba7",
  "0x258e86d2ad936208dc4faebd94dcb560775b4a8a1d706f968387f99f03e9f1af",
  "0x05721de377a87fe563e9012cbe21790b472bb4d430248322a7d55c340e99cc19",
  "0x090bfc4cc3a2866a647c6fa30145eee92e99040f2993d11564bd465664203d05",
  "0x24f174edec8ffbdea445407a17c7561917dab67efc2066314e02169a5f2bd176",
  "0x0a3ecad8587b9b576b30d87b26e7df73a01e0cab533609f89133b635d47da8e6",
  "0x2e90b8eab7dcc8a1fafa1010d660b076ddd9e5ebd03daed8c86b72ab7a283bdc",
  "0x11a1e63d4bcdf3bbd6063b3ed48c4fb16c6a309b13e07580e3f839d499534282",
  "0x2c48eb427f0f886a60397a3fba5d15f6bd143ae5f174a10d22bde36a61101986",
  "0x037cd7c51c74293d8ffb4f0e5f651b0c25c1dc2a353de5d50c9aa1b44bf9ae8a",
  "0x158cfadd0317fc74ea136cf413ae55930ca54df49b188d9dd13f00577daa8087",
  "0x07335e0b5bd0204ec32988ef68a2359fca5a1958bf40f9d71dd4841ee5cec9e9",
  "0x1da000a45af447517f4fca21d41b7673cade7a1211dc6e5d52f65c1799812a81",
  "0x106b7a78ff69c3215c39f302b148d1c570a5285ff53c440577007d078445716b",
  "0x00d4db11baf5c43d1c76c87f22f1f33c5437298a2c6beb780703e7e92bee7d6f",
  "0x1efe71b822044ba01cc663f102b111b0dabd3ca7f73402a29ecce5227706a2a5",
  "0x13754ca04c0c2a7b4e5f82c6aae25705d6e0ee0b7094d05641b7adeef34a8449",
  "0x0657e306bfe45d146af75eb24df29e329a963f4d5936d9ceb9484c023083f593",
  "0x10818f8e49e6bcb2947974a99dd7044f39d593aca03d1d409576fdb4d42c499c",
];

export async function merkleTree(leaves) {
  const TREE_HEIGHT = 20;
  const tree = new PoseidonTree(TREE_HEIGHT, ZERO_VALUES);

  // Initialize tree with no leaves (all zeros)
  await tree.init();

  // Insert some leaves (from input)
  for (const leaf of leaves) {
    await tree.insert(leaf);
  }

  return tree;
}
