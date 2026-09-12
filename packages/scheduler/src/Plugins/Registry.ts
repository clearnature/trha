// Service registry (Cordis-style: services are found by name, not by
// importing a concrete implementation).  Plugins declare `inject` names
// and receive the matching services through the context.

/** A named runtime service. */
export type Service = unknown;

/** A declared service with its capability surface. */
export interface ServiceInfo {
  name: string;
  capabilities: string[];
}

export class ServiceRegistry {
  private services: Map<string, Service> = new Map();
  private caps: Map<string, string[]> = new Map();

  /** Register a service under a stable key (e.g. 'events', 'sessions'). */
  register(name: string, service: Service, capabilities: string[] = []): void {
    if (this.services.has(name)) {
      throw new Error(`Service ${name} is already registered`);
    }
    this.services.set(name, service);
    this.caps.set(name, capabilities);
  }

  has(name: string): boolean {
    return this.services.has(name);
  }

  /** Resolve a service; `undefined` when the name is unknown. */
  get(name: string): Service | undefined {
    return this.services.get(name);
  }

  /** Resolve a service, throwing a descriptive error when missing. */
  require(name: string): Service {
    const svc = this.services.get(name);
    if (svc === undefined) {
      throw new Error(`Service ${name} is not registered`);
    }
    return svc;
  }

  names(): string[] {
    return Array.from(this.services.keys());
  }

  /** Declared capability surface for every registered service. */
  describe(): ServiceInfo[] {
    return Array.from(this.services.keys()).map(name => ({
      name,
      capabilities: this.caps.get(name) ?? [],
    }));
  }

  capabilities(name: string): string[] {
    return this.caps.get(name) ?? [];
  }
}
