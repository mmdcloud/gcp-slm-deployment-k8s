import bentoml
from transformers import pipeline

@bentoml.service(
    resources={"gpu": 1},
    traffic={"timeout": 60}
)
class SLMService:
    def __init__(self):
        # Load a small model like Llama-3.2-3B
        self.generator = pipeline("text-generation", model="meta-llama/Llama-3.2-3B-Instruct")

    @bentoml.api
    def generate(self, prompt: str) -> str:
        result = self.generator(prompt, max_new_tokens=100)
        return result[0]['generated_text']