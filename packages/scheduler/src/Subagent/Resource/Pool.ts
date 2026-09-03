// Resource Pool for Subagents - Phase 6

export interface Resource {
  id: string;
  type: string;
  status: 'available' | 'in-use' | 'error';
  metadata: Record<string, unknown>;
  lastUsed?: Date;
  createdAt: Date;
}

export interface PoolConfig {
  maxSize: number;
  minSize: number;
  acquireTimeout: number;
  idleTimeout: number;
  maxRetries: number;
}

export class ResourcePool {
  private resources: Map<string, Resource> = new Map();
  private available: Set<string> = new Set();
  private config: PoolConfig;
  private waitingQueue: Array<{
    resolve: (resource: Resource) => void;
    reject: (error: Error) => void;
    timeout: NodeJS.Timeout;
  }> = [];

  constructor(config: PoolConfig) {
    this.config = config;
  }

  // Initialize the pool with resources
  async initialize(resources: Array<Omit<Resource, 'createdAt' | 'status'>>): Promise<void> {
    for (const resource of resources) {
      const fullResource: Resource = {
        ...resource,
        status: 'available',
        createdAt: new Date(),
      };

      this.resources.set(resource.id, fullResource);
      this.available.add(resource.id);
    }
  }

  // Acquire a resource from the pool
  async acquire(type?: string): Promise<Resource> {
    // Try to find an available resource
    const resourceId = this.findAvailableResource(type);

    if (resourceId) {
      const resource = this.resources.get(resourceId)!;
      resource.status = 'in-use';
      resource.lastUsed = new Date();
      this.available.delete(resourceId);
      return resource;
    }

    // If no resource available, wait for one
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const index = this.waitingQueue.findIndex((w) => w.resolve === resolve);
        if (index !== -1) {
          this.waitingQueue.splice(index, 1);
        }
        reject(new Error('Timeout waiting for resource'));
      }, this.config.acquireTimeout);

      this.waitingQueue.push({ resolve, reject, timeout });
    });
  }

  // Release a resource back to the pool
  async release(resourceId: string): Promise<void> {
    const resource = this.resources.get(resourceId);
    if (!resource) {
      throw new Error(`Resource ${resourceId} not found`);
    }

    resource.status = 'available';
    resource.lastUsed = new Date();
    this.available.add(resourceId);

    // Check if anyone is waiting for a resource
    if (this.waitingQueue.length > 0) {
      const waiter = this.waitingQueue.shift()!;
      clearTimeout(waiter.timeout);

      const availableResource = this.findAvailableResource();
      if (availableResource) {
        const res = this.resources.get(availableResource)!;
        res.status = 'in-use';
        res.lastUsed = new Date();
        this.available.delete(availableResource);
        waiter.resolve(res);
      }
    }
  }

  // Find an available resource
  private findAvailableResource(type?: string): string | undefined {
    for (const resourceId of this.available) {
      const resource = this.resources.get(resourceId)!;
      if (!type || resource.type === type) {
        return resourceId;
      }
    }
    return undefined;
  }

  // Get pool statistics
  getStatistics(): {
    total: number;
    available: number;
    inUse: number;
    error: number;
    waiting: number;
  } {
    const resources = Array.from(this.resources.values());

    return {
      total: resources.length,
      available: resources.filter((r) => r.status === 'available').length,
      inUse: resources.filter((r) => r.status === 'in-use').length,
      error: resources.filter((r) => r.status === 'error').length,
      waiting: this.waitingQueue.length,
    };
  }

  // Get all resources
  getResources(): Resource[] {
    return Array.from(this.resources.values());
  }

  // Get a specific resource
  getResource(resourceId: string): Resource | undefined {
    return this.resources.get(resourceId);
  }

  // Mark a resource as error
  async markError(resourceId: string): Promise<void> {
    const resource = this.resources.get(resourceId);
    if (!resource) {
      throw new Error(`Resource ${resourceId} not found`);
    }

    resource.status = 'error';
    this.available.delete(resourceId);
  }

  // Remove a resource from the pool
  async remove(resourceId: string): Promise<void> {
    this.resources.delete(resourceId);
    this.available.delete(resourceId);
  }

  // Clean up idle resources
  async cleanup(): Promise<void> {
    const now = new Date();

    for (const [resourceId, resource] of this.resources.entries()) {
      if (resource.status === 'available' && resource.lastUsed) {
        const idleTime = now.getTime() - resource.lastUsed.getTime();
        if (idleTime > this.config.idleTimeout) {
          this.resources.delete(resourceId);
          this.available.delete(resourceId);
        }
      }
    }
  }
}