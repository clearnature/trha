// Parallel scheduler for trha

export interface Task<T> {
  id: string;
  execute: () => Promise<T>;
}

export interface TaskResult<T> {
  id: string;
  result?: T;
  error?: Error;
}

export interface ParallelConfig {
  maxConcurrency: number;
  timeout?: number;
}

export class ParallelScheduler {
  private config: ParallelConfig;

  constructor(config: ParallelConfig) {
    this.config = config;
  }

  async parallel<T>(tasks: Task<T>[]): Promise<TaskResult<T>[]> {
    const results: TaskResult<T>[] = [];
    const executing: Promise<void>[] = [];

    for (const task of tasks) {
      const promise = this.executeTask(task).then((result) => {
        results.push(result);
      });

      executing.push(promise);

      if (executing.length >= this.config.maxConcurrency) {
        await Promise.race(executing);
        executing.splice(
          executing.findIndex((p) => p === promise),
          1
        );
      }
    }

    await Promise.all(executing);
    return results;
  }

  private async executeTask<T>(task: Task<T>): Promise<TaskResult<T>> {
    try {
      const result = await task.execute();
      return { id: task.id, result };
    } catch (error) {
      return {
        id: task.id,
        error: error instanceof Error ? error : new Error(String(error)),
      };
    }
  }

  async pipeline<T>(stages: ((input: T) => Promise<T>)[], initial: T): Promise<T> {
    let current = initial;
    for (const stage of stages) {
      current = await stage(current);
    }
    return current;
  }

  async mapReduce<T, R>(
    items: T[],
    mapper: (item: T) => Promise<R>,
    reducer: (results: R[]) => R
  ): Promise<R> {
    const tasks: Task<R>[] = items.map((item, index) => ({
      id: `map-${index}`,
      execute: () => mapper(item),
    }));

    const results = await this.parallel(tasks);
    const values = results
      .filter((r) => r.result !== undefined)
      .map((r) => r.result as R);

    return reducer(values);
  }
}