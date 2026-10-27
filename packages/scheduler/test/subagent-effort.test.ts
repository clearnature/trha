import { afterEach, describe, expect, it } from 'vitest';
import { roleEffort, subagentEffort, subagentEfforts } from '../src/Server/index.js';

const EFFORT = 'TRHA_SUBAGENT_EFFORT';
const ROLES = 'TRHA_ROLE_EFFORTS';
const PROFILES = 'TRHA_SUBAGENT_EFFORTS';

afterEach(() => {
  delete process.env[EFFORT];
  delete process.env[ROLES];
  delete process.env[PROFILES];
});

describe('subagent effort', () => {
  it('is unset by default', () => {
    delete process.env[EFFORT];
    expect(subagentEffort()).toBeUndefined();
  });

  it('treats auto as unset', () => {
    process.env[EFFORT] = 'auto';
    expect(subagentEffort()).toBeUndefined();
  });

  it('returns a trimmed concrete level', () => {
    process.env[EFFORT] = ' high ';
    expect(subagentEffort()).toBe('high');
  });
});

describe('role effort', () => {
  it('returns the level for a matching role (case-insensitive)', () => {
    process.env[ROLES] = 'planner=high, coder=low';
    expect(roleEffort('Planner')).toBe('high');
    expect(roleEffort('coder')).toBe('low');
  });

  it('is unset for an unknown or missing role', () => {
    process.env[ROLES] = 'planner=high';
    expect(roleEffort('reviewer')).toBeUndefined();
    expect(roleEffort(undefined)).toBeUndefined();
  });

  it('treats auto as unset', () => {
    process.env[ROLES] = 'planner=auto';
    expect(roleEffort('planner')).toBeUndefined();
  });
});

describe('subagent profile effort', () => {
  it('returns the level for a matching profile (case-insensitive)', () => {
    process.env[PROFILES] = 'reviewer=max, task=high';
    expect(subagentEfforts('Reviewer')).toBe('max');
    expect(subagentEfforts('task')).toBe('high');
  });

  it('is unset for an unknown profile', () => {
    process.env[PROFILES] = 'reviewer=max';
    expect(subagentEfforts('coder')).toBeUndefined();
  });

  it('treats auto as unset', () => {
    process.env[PROFILES] = 'task=auto';
    expect(subagentEfforts('task')).toBeUndefined();
  });
});
