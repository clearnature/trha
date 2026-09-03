// Error Handling for Subagents - Phase 6

export type ErrorType =
  | 'timeout'
  | 'connection'
  | 'execution'
  | 'validation'
  | 'resource'
  | 'unknown';

export interface SubAgentError {
  type: ErrorType;
  message: string;
  subagentId?: string;
  taskId?: string;
  details?: unknown;
  timestamp: Date;
  retryable: boolean;
}

export interface ErrorHandlerConfig {
  maxRetries: number;
  retryDelay: number;
  retryBackoff: number;
  logErrors: boolean;
}

export class ErrorHandler {
  private config: ErrorHandlerConfig;
  private errors: SubAgentError[] = [];

  constructor(config: ErrorHandlerConfig) {
    this.config = config;
  }

  // Handle an error
  async handleError(error: unknown, context: { subagentId?: string; taskId?: string }): Promise<SubAgentError> {
    const subagentError = this.classifyError(error, context);

    if (this.config.logErrors) {
      console.error(`[ErrorHandler] ${subagentError.type}: ${subagentError.message}`, {
        subagentId: subagentError.subagentId,
        taskId: subagentError.taskId,
        details: subagentError.details,
      });
    }

    this.errors.push(subagentError);

    return subagentError;
  }

  // Classify an error
  private classifyError(error: unknown, context: { subagentId?: string; taskId?: string }): SubAgentError {
    const timestamp = new Date();

    if (error instanceof Error) {
      // Timeout error
      if (error.message.includes('timeout') || error.message.includes('ETIMEDOUT')) {
        return {
          type: 'timeout',
          message: error.message,
          subagentId: context.subagentId,
          taskId: context.taskId,
          timestamp,
          retryable: true,
        };
      }

      // Connection error
      if (error.message.includes('ECONNREFUSED') || error.message.includes('ENOTFOUND')) {
        return {
          type: 'connection',
          message: error.message,
          subagentId: context.subagentId,
          taskId: context.taskId,
          timestamp,
          retryable: true,
        };
      }

      // Validation error
      if (error.message.includes('validation') || error.message.includes('invalid')) {
        return {
          type: 'validation',
          message: error.message,
          subagentId: context.subagentId,
          taskId: context.taskId,
          timestamp,
          retryable: false,
        };
      }

      // Execution error
      return {
        type: 'execution',
        message: error.message,
        subagentId: context.subagentId,
        taskId: context.taskId,
        details: error.stack,
        timestamp,
        retryable: true,
      };
    }

    // Unknown error
    return {
      type: 'unknown',
      message: String(error),
      subagentId: context.subagentId,
      taskId: context.taskId,
      timestamp,
      retryable: false,
    };
  }

  // Check if an error is retryable
  isRetryable(error: SubAgentError): boolean {
    return error.retryable;
  }

  // Get retry delay for an error
  getRetryDelay(attempt: number): number {
    return this.config.retryDelay * Math.pow(this.config.retryBackoff, attempt - 1);
  }

  // Get all errors
  getErrors(): SubAgentError[] {
    return [...this.errors];
  }

  // Get errors for a specific subagent
  getErrorsForSubagent(subagentId: string): SubAgentError[] {
    return this.errors.filter((e) => e.subagentId === subagentId);
  }

  // Get errors for a specific task
  getErrorsForTask(taskId: string): SubAgentError[] {
    return this.errors.filter((e) => e.taskId === taskId);
  }

  // Clear errors
  clearErrors(): void {
    this.errors = [];
  }

  // Get error statistics
  getStatistics(): {
    total: number;
    byType: Record<ErrorType, number>;
    retryable: number;
    nonRetryable: number;
  } {
    const byType: Record<ErrorType, number> = {
      timeout: 0,
      connection: 0,
      execution: 0,
      validation: 0,
      resource: 0,
      unknown: 0,
    };

    for (const error of this.errors) {
      byType[error.type]++;
    }

    return {
      total: this.errors.length,
      byType,
      retryable: this.errors.filter((e) => e.retryable).length,
      nonRetryable: this.errors.filter((e) => !e.retryable).length,
    };
  }
}