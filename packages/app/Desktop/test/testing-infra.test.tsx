// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import React from 'react';

function Probe() { return <h1>desktop-works</h1>; }

describe('testing infra', () => {
  it('renders with jsdom via @testing-library', () => {
    render(<Probe />);
    expect(screen.getByText('desktop-works')).toBeTruthy();
  });
});
