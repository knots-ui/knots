const workerCount = Math.max(1, (globalThis.navigator?.hardwareConcurrency ?? 4) - 1);

export class WorkerPool {
  constructor({
    module,
    memory,
    exports,
    pointerSize,
    extensions = [],
    minWorkers = 0,
    onComplete,
    onError,
  }) {
    this.extensions = extensions;
    this.maxWorkers = Math.max(workerCount, minWorkers);
    this.module = module;
    this.memory = memory;
    this.exports = exports;
    this.pointerSize = pointerSize;
    this.onComplete = onComplete;
    this.onError = onError;
    this.workers = [];
    this.tasks = new Map();
    this.pending = [];
    this.startingWorkers = 0;
    this.nextWorkerId = 0;
  }

  async init() {
    await this.startWorker();
  }

  async startWorker() {
    this.startingWorkers += 1;
    try {
      await this.addWorker();
    } finally {
      this.startingWorkers -= 1;
    }
    this.pump();
    this.scale();
  }

  addWorker() {
    return new Promise((resolve, reject) => {
      const worker = new Worker(new URL("./knots-worker.js", import.meta.url), {
        type: "module",
        name: `knots-${this.nextWorkerId++}`,
      });
      const record = {
        worker,
        ready: false,
        failed: false,
        busy: false,
        stack: null,
      };
      worker.onmessage = ({ data }) => {
        if (data.type === "ready") {
          record.stack = this.exports.knots_worker_stack_alloc();
          if (record.stack === 0 || record.stack === 0n) {
            worker.terminate();
            reject(new Error("Knots worker stack allocation failed"));
            return;
          }
          record.ready = true;
          this.workers.push(record);
          resolve();
          return;
        }
        if (data.type === "init-error") {
          worker.terminate();
          reject(new Error(`Knots worker initialization failed: ${data.error}`));
          return;
        }
        if (data.type === "complete") {
          this.finishTask(Number(data.task), false);
          record.busy = false;
          this.pump();
          return;
        }
        if (data.type === "run-error") {
          this.finishTask(Number(data.task), false);
          record.busy = false;
          this.onError(new Error(`Knots worker task failed: ${data.error}`));
          this.pump();
        }
      };
      worker.onerror = (event) => {
        const error = new Error(event.message || "Knots worker failed");
        if (record.ready) this.failWorker(record, error);
        else {
          worker.terminate();
          reject(error);
        }
      };
      worker.postMessage({
        type: "init",
        module: this.module,
        memory: this.memory,
        pointerSize: this.pointerSize,
        extensions: this.extensions,
      });
    });
  }

  dispatch(task, group, start, context) {
    if (this.workers.length === 0) return false;
    const taskAddress = Number(task);
    this.tasks.set(taskAddress, {
      group: Number(group),
      worker: null,
      forgotten: false,
      message: {
        type: "run",
        task: this.wasmPointer(task),
        start: this.wasmPointer(start),
        context: this.wasmPointer(context),
      },
    });
    this.pending.push(taskAddress);
    this.scale();
    this.pump();
    return true;
  }

  wasmPointer(value) {
    return this.pointerSize === 8 ? BigInt(value) : value;
  }

  scale() {
    const desiredWorkers = Math.min(this.maxWorkers, this.tasks.size);
    while (this.workers.length + this.startingWorkers < desiredWorkers) {
      this.startWorker().catch((error) => {
        this.onError(error);
      });
    }
  }

  pump() {
    for (const record of this.workers) {
      if (record.busy) continue;
      let taskAddress;
      let task;
      do {
        taskAddress = this.pending.shift();
        if (taskAddress === undefined) return;
        task = this.tasks.get(taskAddress);
      } while (!task);

      task.worker = record;
      record.busy = true;
      try {
        record.worker.postMessage({ ...task.message, stack: record.stack });
      } catch (error) {
        record.busy = false;
        this.finishTask(taskAddress, true);
        this.onError(error);
      }
    }
  }

  finishTask(taskAddress, abort) {
    const task = this.tasks.get(taskAddress);
    if (!task) return;
    this.tasks.delete(taskAddress);
    if (task.forgotten) return;
    const wasmTask = this.wasmPointer(taskAddress);
    if (abort) this.exports.knots_worker_abort(wasmTask);
    this.exports.knots_worker_release(wasmTask);
    this.onComplete();
  }

  failWorker(record, error) {
    if (record.failed) return;
    record.failed = true;
    record.worker.terminate();
    this.exports.knots_worker_stack_free(record.stack);
    this.workers = this.workers.filter((candidate) => candidate !== record);
    for (const [taskAddress, task] of this.tasks) {
      if (task.worker !== record) continue;
      this.finishTask(taskAddress, true);
    }
    this.onError(error);
    this.pump();
    this.scale();
  }

  forgetGroup(group) {
    const key = Number(group);
    for (const task of this.tasks.values()) {
      if (task.group === key) task.forgotten = true;
    }
  }
}
