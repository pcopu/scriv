// Only the isolated discussions-assets journey binds this test Worker as MEDIA.
import { WorkerEntrypoint } from 'cloudflare:workers';

export class MediaFault extends WorkerEntrypoint {
  async #step(method, key) {
    const response = await this.env.CONTROL.fetch(`http://media-fixture.invalid/${method}`, { method: 'POST', body: key });
    if (!response.ok) throw new Error('Unexpected media fixture request');
    return response.text();
  }

  async put(key, bytes, options) {
    const mode = await this.#step('put', key);
    await this.env.BACKING.put(key, bytes, options);
    if (mode === 'lose-ack') throw new Error('Synthetic storage acknowledgement lost');
  }

  async head(key) {
    if (await this.#step('head', key) === 'defer') throw new Error('Synthetic metadata unavailable');
    const object = await this.env.BACKING.head(key);
    return object ? { size: object.size, customMetadata: object.customMetadata } : null;
  }

  async delete(key) {
    if (!await this.env.BACKING.head(key)) throw new Error('Expected the exact fixture object before deletion');
    await this.#step('delete', key);
    await this.env.BACKING.delete(key);
  }
}
