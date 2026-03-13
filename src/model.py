"""
Package a small LLM (TinyLlama-1.1B or GPT-2) using BentoML.
Run: python model.py  →  saves model to local BentoML store.
"""
import bentoml
from transformers import AutoModelForCausalLM, AutoTokenizer
import torch

MODEL_ID = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"  # swap for any HF model

def save_model():
    print(f"Loading {MODEL_ID} from HuggingFace …")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.float16,
        device_map="auto",
    )

    # Save into BentoML model store with metadata
    saved = bentoml.transformers.save_model(
        "tinyllama-chat",
        model,
        custom_objects={"tokenizer": tokenizer},
        metadata={
            "model_id": MODEL_ID,
            "framework": "transformers",
            "task": "text-generation",
        },
        labels={"team": "ml-platform", "env": "prod"},
    )
    print(f"Saved: {saved}")
    return saved

if __name__ == "__main__":
    save_model()