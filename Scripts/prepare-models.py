#!/usr/bin/env python3
"""Convert Kokoro's PyTorch checkpoint and voice vectors into the safetensors files
MoxSpeakNative loads.

The outputs are hundreds of megabytes and are gitignored. This script is how you get
them back. Provenance for the inputs is in Sources/Vendor/VENDORED.md.

    python3 Scripts/prepare-models.py \
        --checkpoint <path>/kokoro-v1_0.pth \
        --voices     <path>/voices/v1_0 \
        --out        Models

Writes:
    Models/kokoro-v1_0.safetensors        f32, ~312 MB
    Models/kokoro-v1_0-fp16.safetensors   f16, ~156 MB
    Models/voices/<name>.safetensors      one tensor named "voice"

Needs torch + safetensors. The Kokoro-FastAPI venv already has both:
    /Users/guymorita/Dev/Kokoro-FastAPI/.venv/bin/python
"""

import argparse
import pathlib
import sys

import torch
from safetensors.torch import save_file

# Kokoro ships voices for many languages; the native engine's G2P is US English only,
# so converting the rest would be dead weight on disk.
ENGLISH_PREFIXES = ("af_", "am_", "bf_", "bm_")


def flatten(state_dict, prefix=""):
    """Kokoro's .pth nests one state dict per component ("bert", "decoder", ...), and
    every key inside carries a leading "module." left over from the DataParallel wrapper
    it was trained under. safetensors is flat and KokoroSwift looks up
    "bert.embeddings.word_embeddings.weight", so flatten and drop the "module." segment.
    Leaving it in produces a file that loads fine and then crashes on the first weight
    lookup."""
    flat = {}
    for key, value in state_dict.items():
        if key == "module":
            full = prefix
        else:
            full = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            flat.update(flatten(value, full))
        elif key.startswith("module."):
            flat[f"{prefix}.{key[len('module.'):]}" if prefix else key[len("module."):]] = value.contiguous()
        else:
            flat[full] = value.contiguous()
    return flat


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=pathlib.Path)
    parser.add_argument("--voices", required=True, type=pathlib.Path)
    parser.add_argument("--out", default=pathlib.Path("Models"), type=pathlib.Path)
    parser.add_argument(
        "--all-languages",
        action="store_true",
        help="convert every voice, not just the English ones",
    )
    args = parser.parse_args()

    out = args.out
    (out / "voices").mkdir(parents=True, exist_ok=True)

    state = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    flat = flatten(state)
    print(f"{len(flat)} tensors from {args.checkpoint}")

    f32 = {k: v.to(torch.float32) for k, v in flat.items()}
    save_file(f32, str(out / "kokoro-v1_0.safetensors"))
    print(f"wrote {out / 'kokoro-v1_0.safetensors'}")

    # fp16 is a straight cast of the same tensors. MLX computes in whatever dtype the
    # weights arrive in, so this file is the only thing that selects half precision --
    # there is no runtime flag and nothing is converted on load.
    f16 = {k: v.to(torch.float16) for k, v in flat.items()}
    save_file(f16, str(out / "kokoro-v1_0-fp16.safetensors"))
    print(f"wrote {out / 'kokoro-v1_0-fp16.safetensors'}")

    count = 0
    for path in sorted(args.voices.glob("*.pt")):
        if not args.all_languages and not path.name.startswith(ENGLISH_PREFIXES):
            continue
        vector = torch.load(path, map_location="cpu", weights_only=True)
        save_file(
            {"voice": vector.contiguous().to(torch.float32)},
            str(out / "voices" / f"{path.stem}.safetensors"),
        )
        count += 1
    print(f"wrote {count} voices to {out / 'voices'}")


if __name__ == "__main__":
    sys.exit(main())
