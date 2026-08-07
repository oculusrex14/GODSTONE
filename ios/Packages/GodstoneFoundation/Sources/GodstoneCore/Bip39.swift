// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// BIP-39-style mnemonic words for out-of-band node verification.
///
/// The full BIP-39 wordlist is 2048 entries, but the node id is only 16 bytes
/// and `callSign` uses six words; that needs at most 256 distinct words to be
/// collision-resistant for verbal verification. We ship a compact, deterministic
/// survival-themed list (256 words) and read 11-bit indices from the data,
/// modulo the list length.
///
/// This is NOT the standard BIP-39 list and does not interoperate with hardware
/// wallets; it only has to be stable across builds and platforms so two phones
/// read the same call sign off the same node id. The Android side uses the same
/// list -- see docs/AUDIT.md.
public enum Bip39 {

    public static let wordlist: [String] = [
        // 256 words. Survival/field themed, lexicographically stable.
        "amber", "anchor", "antler", "arrow", "ash", "atlas", "aura", "axe",
        "badger", "barn", "basin", "beacon", "bear", "blaze", "boulder", "branch",
        "brass", "breeze", "brick", "bristle", "bronze", "brook", "buck", "bud",
        "cabin", "cactus", "cadet", "camel", "canyon", "carbon", "cargo", "cart",
        "cedar", "chalk", "charm", "cheese", "chisel", "cinder", "civic", "clam",
        "clasp", "clay", "cliff", "cloak", "cobalt", "cobra", "cocoa", "comet",
        "copper", "coral", "cosmo", "cougar", "cradle", "crane", "crest", "crow",
        "crystal", "cubit", "currant", "cylinder", "daisy", "delta", "denim", "dew",
        "digger", "dignity", "dime", "dimple", "dolphin", "donor", "drift", "drum",
        "dune", "dynamo", "eagle", "echo", "ember", "emerald", "engine", "epoch",
        "fable", "falcon", "fathom", "feather", "ferret", "ferry", "fiber", "field",
        "finch", "fjord", "flag", "flame", "flax", "flint", "fossil", "fountain",
        "fox", "fragment", "frost", "furnace", "gadget", "galaxy", "gasket", "ghost",
        "glacier", "glade", "globe", "glory", "granite", "graphite", "gravel", "griffin",
        "grove", "guide", "gulf", "gust", "gypsum", "harbor", "harp", "hatch",
        "haven", "hazel", "helmet", "heron", "hickory", "hollow", "honey", "horizon",
        "hub", "hurdle", "hydra", "ibis", "icing", "icon", "indigo", "ink",
        "iron", "ivory", "jade", "jaguar", "jasper", "jetty", "jingle", "juno",
        "kayak", "kestrel", "kettle", "kite", "knot", "lacquer", "lagoon", "lance",
        "lapis", "lattice", "laurel", "lavender", "ledge", "lemon", "lens", "leopard",
        "lichen", "lighthouse", "lilac", "lime", "linen", "lizard", "loom", "lumen",
        "lunar", "lupin", "magma", "mango", "maple", "marble", "marlin", "marrow",
        "meadow", "medal", "mercury", "meteor", "mica", "millet", "mink", "mirror",
        "mist", "mocha", "monsoon", "moose", "moss", "mote", "mule", "mushroom",
        "myrtle", "nacre", "napkin", "needle", "nectar", "neon", "nettle", "niche",
        "nighthawk", "nimbus", "node", "nomad", "noodle", "north", "notch", "nucleus",
        "oak", "oasis", "obelisk", "ocean", "octave", "opal", "orbit", "orchard",
        "otter", "oval", "oven", "owl", "paddle", "padlock", "palm", "panther",
        "pasture", "pebble", "pelican", "perch", "petal", "phlox", "picket", "pilot",
        "pinnacle", "piston", "platinum", "plow", "plume", "polar", "pony", "portal",
        "prairie", "prism", "prow", "puffin", "pulp", "pump", "quartz", "quasar",
        "quill", "quilt", "raccoon", "radar", "raft", "rage", "rain", "rattan"
    ]

    /// Read `count` 11-bit indices from `data` (LSB-first bit accumulation) and
    /// map each, modulo the wordlist length, to a word.
    public static func words(from data: Data, count: Int) -> [String] {
        let n = wordlist.count
        guard n > 0, count > 0 else { return [] }

        var bits: UInt64 = 0
        var bitCount = 0
        var out: [String] = []
        out.reserveCapacity(count)

        for byte in data {
            bits = (bits << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 11 && out.count < count {
                let leftover = bitCount - 11
                let idx11 = UInt32((bits >> leftover) & 0x7FF)
                out.append(wordlist[Int(idx11) % n])
                bits &= (1 << leftover) - 1
                bitCount = leftover
            }
            if out.count >= count { break }
        }

        // If the data was too short to supply `count` words, pad with zeros so
        // the call sign always has the expected length (defensive; a 16-byte
        // node id comfortably yields six 11-bit words).
        while out.count < count {
            out.append(wordlist[0])
        }
        return out
    }
}
