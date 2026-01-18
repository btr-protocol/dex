export const log = (msg: string) => console.log(`[${new Date().toISOString().slice(11,23)}] ${msg}`);
export const warn = (msg: string) => console.warn(`[${new Date().toISOString().slice(11,23)}] ${msg}`);
export const error = (msg: string) => console.error(`[${new Date().toISOString().slice(11,23)}] ${msg}`);
