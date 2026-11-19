# SocialForge starter workflows for ComfyUI

Five simplified workflows that SocialForge's AI Studio drives directly. Every one uses core ComfyUI nodes,
except Music, which needs the YuE2 custom nodes. Each was tested end to end on ComfyUI 0.46 with an RTX 5080.

| Workflow | Makes | Models it loads | Time on an RTX 5080 |
|---|---|---|---|
| SocialForge Image | 1024 × 1024 PNG (SocialForge sets the size) | `z_image_turbo_bf16.safetensors` (diffusion model), `qwen_3_4b.safetensors` (text encoder, type lumina2), `ae.safetensors` (VAE) | about 45 s first run, faster after |
| SocialForge Image Text | 1024 × 1024 PNG with words drawn in it (signs, labels, a slogan) | `moss_image_sft_int8_convrot.safetensors` (diffusion model), `qwen3.5_9b_w4a8_gptq.safetensors` (text encoder, type moss_image), `flux2-vae_small.safetensors` (VAE) | about 30 s |
| SocialForge Video Vertical | 704 × 1216 MP4, 97 frames at 24 fps (about 4 s) | `ltx-2.3-22b-dev-fp8.safetensors` (checkpoint), `gemma_3_12B_it_fp4_mixed.safetensors` (text encoder), `ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors` (LoRA) | about 2 min first run, about 30 s after |
| SocialForge Video Square | 768 × 768 MP4, same models | same as above | about 30 s |
| SocialForge Music | MP3 song from a style line and lyrics | `yue2_3b_bf16.safetensors` plus the YuE2 custom nodes (`YuE2GenerateMusic`, `EmptyYuE2LatentAudio`) | about 35 s for a short song |

## Two folders, two uses

- **`comfyui/`**: editor files. In ComfyUI, drag one onto the canvas (or Workflow › Open) to look at it, change models, and run it.
- **`api/`**: the same graphs in ComfyUI's API format, the format SocialForge runs. In SocialForge they ship inside
  the app: **AI Studio › Workflow › Add Starter Workflows**. You can also import one with **Import Workflow (API format)…**.

## How SocialForge fills them

SocialForge finds its inputs by node type, so you can swap models freely as long as the shape stays:

- one `KSampler` (its `seed` is set per run)
- a workflow whose name contains the word "Text" is treated as one that draws words: AI Studio turns on **Text in image**,
  stops adding "no text" to the prompt, and keeps the workflow's own negative prompt. Put the words in quotes, and say
  "only the words …" so the model doesn't invent extra small print
- the prompt in a `CLIPTextEncode` reaching the sampler's `positive` (through `LTXVConditioning` is fine), a separate one for `negative`
- size and length on the empty latent (`EmptySD3LatentImage`, `EmptyFlux2LatentImage`, `EmptyLTXVLatentVideo`, …); video length is rounded to 8n + 1 frames
- music: the `style` (or `tags`) and `lyrics` inputs and `max_duration` on the music node
- exactly one output node: `SaveImage`, `SaveVideo` (mp4, h264), or `SaveAudioMP3`

Put the model files where your ComfyUI expects them (`models/diffusion_models`, `models/text_encoders`, `models/vae`,
`models/checkpoints`, `models/loras`). If a file name differs on your install, change it in the loader node, then
export with Workflow › Export (API) and import that file into SocialForge.
