// Passes the mixed meeting sound to the page in small blocks, for transcription.
class PcmTap extends AudioWorkletProcessor {
  process(inputs) {
    const channels = inputs[0];
    if (channels && channels.length) {
      const length = channels[0].length;
      const mono = new Float32Array(length);
      for (const channel of channels) {
        for (let i = 0; i < length; i++) mono[i] += channel[i] / channels.length;
      }
      this.port.postMessage(mono, [mono.buffer]);
    }
    return true;
  }
}

registerProcessor('pcm-tap', PcmTap);
