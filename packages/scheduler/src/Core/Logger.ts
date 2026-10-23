// Logger for trha scheduler

import winston from 'winston';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface LoggerConfig {
  level: LogLevel;
  prefix?: string | undefined;
}

export class Logger {
  private logger: winston.Logger;
  private prefix: string;

  constructor(config: LoggerConfig) {
    this.prefix = config.prefix || '';

    this.logger = winston.createLogger({
      level: config.level,
      format: winston.format.combine(
        winston.format.timestamp({ format: 'YYYY-MM-DD HH:mm:ss' }),
        winston.format.printf(({ timestamp, level, message }) => {
          const prefixStr = this.prefix ? `[${this.prefix}] ` : '';
          return `${timestamp} [${level.toUpperCase()}] ${prefixStr}${message}`;
        })
      ),
      transports: [new winston.transports.Console()],
    });
  }

  debug(message: string, ...args: unknown[]): void {
    this.logger.debug(message, ...args);
  }

  info(message: string, ...args: unknown[]): void {
    this.logger.info(message, ...args);
  }

  warn(message: string, ...args: unknown[]): void {
    this.logger.warn(message, ...args);
  }

  error(message: string, ...args: unknown[]): void {
    this.logger.error(message, ...args);
  }
}

export function createLogger(level: LogLevel = 'info', prefix?: string): Logger {
  return new Logger({ level, prefix });
}