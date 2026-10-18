import mongoose, { Schema, Document } from 'mongoose';

export interface ISwapTrade extends Document {
    userAddress: string;
    tokenIn: string;
    tokenOut: string;
    amountIn: string;
    amountOut: string;
    txHash?: string;
    timestamp: Date;
}

const SwapTradeSchema: Schema = new Schema({
    userAddress: { type: String, required: true },
    tokenIn: { type: String, required: true },
    tokenOut: { type: String, required: true },
    amountIn: { type: String, required: true }, // Using string for precision
    amountOut: { type: String, required: true },
    txHash: { type: String, index: true }, // looked up for idempotency; not unique because older rows may hold empty/duplicate values
    timestamp: { type: Date, default: Date.now }
});

export default mongoose.model<ISwapTrade>('SwapTrade', SwapTradeSchema);
