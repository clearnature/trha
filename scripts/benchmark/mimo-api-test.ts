// MIMO API test script for gh-harness

import axios from 'axios';

// Configuration
const API_KEY = 'REMOVED_API_KEY';
const BASE_URL = 'https://token-plan-cn.xiaomimimo.com/v1';
const MODEL = 'mimo-v2.5-pro';

// Test results
interface TestResult {
  name: string;
  status: 'passed' | 'failed';
  tokenPerSecond?: number;
  response?: string;
  correctness?: boolean;
  error?: string;
}

// API client
const client = axios.create({
  baseURL: BASE_URL,
  headers: {
    'Authorization': `Bearer ${API_KEY}`,
    'Content-Type': 'application/json',
  },
});

// Test API connectivity
async function testApiConnectivity(): Promise<TestResult> {
  try {
    const response = await client.get('/models');
    return {
      name: 'API Connectivity',
      status: 'passed',
    };
  } catch (error) {
    return {
      name: 'API Connectivity',
      status: 'failed',
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

// Test simple prompt
async function testSimplePrompt(): Promise<TestResult> {
  try {
    const startTime = Date.now();
    const response = await client.post('/chat/completions', {
      model: MODEL,
      messages: [{ role: 'user', content: 'Hello, how are you?' }],
      max_tokens: 100,
      temperature: 0.7,
    });
    const endTime = Date.now();
    
    const content = response.data.choices[0]?.message?.content;
    const tokens = response.data.usage?.completion_tokens || 0;
    const timeSeconds = (endTime - startTime) / 1000;
    const tokenPerSecond = tokens > 0 ? tokens / timeSeconds : 0;
    
    return {
      name: 'Simple Prompt',
      status: 'passed',
      tokenPerSecond,
      response: content?.substring(0, 100),
    };
  } catch (error) {
    return {
      name: 'Simple Prompt',
      status: 'failed',
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

// Test multi-turn conversation
async function testMultiTurnConversation(): Promise<TestResult> {
  try {
    const messages = [
      { role: 'user', content: 'What is the capital of France?' },
      { role: 'assistant', content: 'The capital of France is Paris.' },
      { role: 'user', content: 'What is the population of Paris?' },
      { role: 'assistant', content: 'Paris has a population of about 2.1 million people in the city proper.' },
      { role: 'user', content: 'What are some famous landmarks in Paris?' },
    ];
    
    const startTime = Date.now();
    const response = await client.post('/chat/completions', {
      model: MODEL,
      messages,
      max_tokens: 200,
      temperature: 0.7,
    });
    const endTime = Date.now();
    
    const content = response.data.choices[0]?.message?.content;
    const tokens = response.data.usage?.completion_tokens || 0;
    const timeSeconds = (endTime - startTime) / 1000;
    const tokenPerSecond = tokens > 0 ? tokens / timeSeconds : 0;
    
    return {
      name: 'Multi-turn Conversation',
      status: 'passed',
      tokenPerSecond,
      response: content?.substring(0, 100),
    };
  } catch (error) {
    return {
      name: 'Multi-turn Conversation',
      status: 'failed',
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

// Test reasoning ability
async function testReasoningAbility(): Promise<TestResult> {
  try {
    const prompt = 'Solve this math problem: If a train travels at 60 km/h for 2 hours, then at 80 km/h for 3 hours, what is the total distance traveled?';
    
    const startTime = Date.now();
    const response = await client.post('/chat/completions', {
      model: MODEL,
      messages: [{ role: 'user', content: prompt }],
      max_tokens: 200,
      temperature: 0.7,
    });
    const endTime = Date.now();
    
    const content = response.data.choices[0]?.message?.content;
    const tokens = response.data.usage?.completion_tokens || 0;
    const timeSeconds = (endTime - startTime) / 1000;
    const tokenPerSecond = tokens > 0 ? tokens / timeSeconds : 0;
    
    // Check if answer is correct (distance = 60*2 + 80*3 = 120 + 240 = 360 km)
    const correctness = content?.includes('360');
    
    return {
      name: 'Reasoning Ability',
      status: 'passed',
      tokenPerSecond,
      response: content?.substring(0, 100),
      correctness,
    };
  } catch (error) {
    return {
      name: 'Reasoning Ability',
      status: 'failed',
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

// Test performance with multiple prompts
async function testPerformance(): Promise<TestResult> {
  try {
    const prompts = [
      'Explain quantum computing in simple terms.',
      'Write a Python function to sort a list.',
      'What are the benefits of renewable energy?',
      'Describe the water cycle.',
      'How does machine learning work?',
    ];
    
    let totalTokens = 0;
    let totalTime = 0;
    
    for (const prompt of prompts) {
      const startTime = Date.now();
      const response = await client.post('/chat/completions', {
        model: MODEL,
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 150,
        temperature: 0.7,
      });
      const endTime = Date.now();
      
      const tokens = response.data.usage?.completion_tokens || 0;
      const timeSeconds = (endTime - startTime) / 1000;
      
      totalTokens += tokens;
      totalTime += timeSeconds;
    }
    
    const avgTokenPerSecond = totalTokens > 0 ? totalTokens / totalTime : 0;
    
    return {
      name: 'Performance',
      status: 'passed',
      tokenPerSecond: avgTokenPerSecond,
    };
  } catch (error) {
    return {
      name: 'Performance',
      status: 'failed',
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

// Generate test report
function generateReport(results: TestResult[]): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  
  let report = `# MIMO API Test Report

**Date**: ${new Date().toISOString()}
**Model**: ${MODEL}
**API Endpoint**: ${BASE_URL}

## Test Results

`;
  
  for (const result of results) {
    report += `### ${result.name}
- Status: ${result.status === 'passed' ? '✓ Passed' : '✗ Failed'}
`;
    
    if (result.tokenPerSecond !== undefined) {
      report += `- Token/s: ${result.tokenPerSecond.toFixed(2)}
`;
    }
    
    if (result.response) {
      report += `- Response: ${result.response}...
`;
    }
    
    if (result.correctness !== undefined) {
      report += `- Correctness: ${result.correctness ? '✓ Correct' : '✗ Incorrect'}
`;
    }
    
    if (result.error) {
      report += `- Error: ${result.error}
`;
    }
    
    report += `
`;
  }
  
  // Performance summary
  const performanceResult = results.find(r => r.name === 'Performance');
  const simpleResult = results.find(r => r.name === 'Simple Prompt');
  const multiTurnResult = results.find(r => r.name === 'Multi-turn Conversation');
  const reasoningResult = results.find(r => r.name === 'Reasoning Ability');
  
  report += `## Performance Summary

- **Simple Prompt**: ${simpleResult?.tokenPerSecond?.toFixed(2) || 'N/A'} token/s
- **Multi-turn**: ${multiTurnResult?.tokenPerSecond?.toFixed(2) || 'N/A'} token/s
- **Reasoning**: ${reasoningResult?.tokenPerSecond?.toFixed(2) || 'N/A'} token/s
- **Average**: ${performanceResult?.tokenPerSecond?.toFixed(2) || 'N/A'} token/s

## Correctness Summary

- **Reasoning Correctness**: ${reasoningResult?.correctness ? '✓ Correct' : '✗ Incorrect'}

## Notes

- All tests performed using max 月套餐 API
- Model: ${MODEL}
- API Endpoint: ${BASE_URL}
- Tests include connectivity, simple prompts, multi-turn conversation, reasoning, and performance
`;
  
  return report;
}

// Main function
async function main() {
  console.log('Starting MIMO API test...');
  
  const results: TestResult[] = [];
  
  // Run tests
  results.push(await testApiConnectivity());
  results.push(await testSimplePrompt());
  results.push(await testMultiTurnConversation());
  results.push(await testReasoningAbility());
  results.push(await testPerformance());
  
  // Generate report
  const report = generateReport(results);
  console.log(report);
  
  // Save report
  const fs = require('fs');
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const reportPath = `benchmarks/mimo-api/mimo-api-test-report-${timestamp}.md`;
  
  fs.mkdirSync('benchmarks/mimo-api', { recursive: true });
  fs.writeFileSync(reportPath, report);
  
  console.log(`\nTest report saved to: ${reportPath}`);
}

// Run main function
main().catch(console.error);