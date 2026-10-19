/// <reference lib="webworker" />
// Whisper speech recognition, running on this computer (the graphics card when the browser allows it).
// The model is downloaded once from Hugging Face and then kept by the browser.
import { pipeline, type AutomaticSpeechRecognitionPipeline } from '@huggingface/transformers';
import { ASR_OPTIONS, chunksOf } from './whisper';

export type WorkerRequest =
  | { type: 'load'; model: string }
  | { type: 'transcribe'; id: string; audio: Float32Array };

export type WorkerResponse =
  | { type: 'progress'; file: string; loaded: number; total: number }
  | { type: 'ready'; device: string }
  | { type: 'error'; id?: string; message: string }
  | { type: 'result'; id: string; chunks: { text: string; start: number; end: number }[] };

let recognizer: AutomaticSpeechRecognitionPipeline | null = null;
let loading: Promise<void> | null = null;

const post = (message: WorkerResponse) => (self as unknown as Worker).postMessage(message);

async function load(model: string) {
  const gpu = (navigator as unknown as { gpu?: { requestAdapter(): Promise<{ features: Set<string> } | null> } }).gpu;
  const adapter = gpu ? await gpu.requestAdapter().catch(() => null) : null;
  const hasGPU = !!adapter;
  const halfFloats = !!adapter?.features.has('shader-f16');
  const device = hasGPU ? 'webgpu' : 'wasm';
  const progress = (event: { status: string; file?: string; loaded?: number; total?: number }) => {
    if (event.status === 'progress' && event.file) post({ type: 'progress', file: event.file, loaded: event.loaded ?? 0, total: event.total ?? 0 });
  };
  // The library's overloads are too many for TypeScript to resolve here, so it is called untyped.
  const create = pipeline as unknown as (task: string, model: string, options: Record<string, unknown>) => Promise<unknown>;
  recognizer = (await create('automatic-speech-recognition', model, {
    device,
    dtype: precision(model, hasGPU, halfFloats),
    progress_callback: progress,
  })) as AutomaticSpeechRecognitionPipeline;
  post({ type: 'ready', device });
}

/** The model files to use: smaller ones where they keep the accuracy, bigger ones where the graphics card needs them. */
function precision(model: string, gpu: boolean, halfFloats: boolean) {
  const large = model.includes('large');
  if (!gpu) return 'q8';
  if (large) return halfFloats ? { encoder_model: 'q4f16', decoder_model_merged: 'q4f16' } : { encoder_model: 'q4', decoder_model_merged: 'q4' };
  return { encoder_model: halfFloats ? 'fp16' : 'fp32', decoder_model_merged: 'q4' };
}

self.onmessage = async (event: MessageEvent<WorkerRequest>) => {
  const request = event.data;
  if (request.type === 'load') {
    loading ??= load(request.model).catch((error) => {
      loading = null;
      post({ type: 'error', message: `The speech model could not load: ${String((error as Error)?.message ?? error)}` });
    });
    return;
  }
  try {
    await loading;
    if (!recognizer) throw new Error('The speech model is not loaded');
    const output = await recognizer(request.audio, ASR_OPTIONS as Record<string, unknown>);
    post({ type: 'result', id: request.id, chunks: chunksOf(output, request.audio.length / 16000) });
  } catch (error) {
    post({ type: 'error', id: request.id, message: String((error as Error)?.message ?? error) });
  }
};
