// Bridge module smoke tests

import { describe, it, expect, beforeEach } from 'vitest';
import { HaskellBridge } from '../../packages/scheduler/src/Bridge/Haskell.js';

describe('Bridge Module Smoke Tests', () => {
  describe('Haskell Bridge', () => {
    let bridge: HaskellBridge;

    beforeEach(() => {
      bridge = new HaskellBridge({
        host: 'localhost',
        port: 3000,
      });
    });

    it('should create bridge with config', () => {
      expect(bridge).toBeDefined();
    });

    it('should have queryModel method', () => {
      expect(bridge.queryModel).toBeDefined();
      expect(typeof bridge.queryModel).toBe('function');
    });

    it('should have verifyType method', () => {
      expect(bridge.verifyType).toBeDefined();
      expect(typeof bridge.verifyType).toBe('function');
    });

    it('should have cacheLookup method', () => {
      expect(bridge.cacheLookup).toBeDefined();
      expect(typeof bridge.cacheLookup).toBe('function');
    });

    it('should have cacheInsert method', () => {
      expect(bridge.cacheInsert).toBeDefined();
      expect(typeof bridge.cacheInsert).toBe('function');
    });
  });
});