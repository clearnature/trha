// Main test index - imports all test modules

import './core.test.js';
import './protocol.test.js';
import './bridge.test.js';

// Re-export all tests for CI/CD
export * from './core.test.js';
export * from './protocol.test.js';
export * from './bridge.test.js';