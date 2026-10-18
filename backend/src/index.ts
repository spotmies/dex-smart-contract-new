import 'dotenv/config';

import app from './app.js';
import chartRoutes from './routes/chartRoutes.js';
import { priceService } from './services/priceService.js';
import connectDB from './config/db.js';
import BlockchainService from './services/BlockchainService.js';
import { startPerpEventListener } from './services/PerpEventListener.js';
import { LiquidationKeeper } from './keepers/LiquidationKeeper.js';
import { RequestKeeper } from './keepers/RequestKeeper.js';
import { whaleStatsService } from './services/WhaleStatsService.js';

// Global error handlers for unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
    // Suppress "invalid block range params" error - it's about historical queries only
    // The event listener will still work for new events
    if (reason && typeof reason === 'object') {
        const error = reason as any;
        if (error.code === -32000 && error.message?.includes('invalid block range params')) {
            // Silently ignore this error - it doesn't affect new event monitoring
            return;
        }
    }

    console.error('Unhandled Rejection detected:');
    console.error('Reason:', reason);
    if (reason && typeof reason === 'object') {
        console.error('Error code:', (reason as any).code);
        console.error('Error message:', (reason as any).message);
    }
    // Log but don't exit - let the retry logic handle it
    // This is especially important for RPC errors that might be transient
    console.error('This error will be handled by retry logic. App will continue running.');
});

process.on('uncaughtException', (error) => {
    console.error('Uncaught Exception:', error);
    process.exit(1);
});

const PORT = process.env.PORT || 3000;

app.use('/api/chart', chartRoutes);




// Connect to Database
connectDB().then(() => {
    // Start Services only after DB is connected

    // 1. Event Listener
    try {
        startPerpEventListener();
        console.log("Perp Event Listener started");
    } catch (e) {
        console.error("Failed to start Perp Event Listener:", e);
    }

    // 1b. P2P trade reconciler: keeps the Trade index in step with the escrow contract (chat access depends on it)
    BlockchainService.startPurchaseReconciler().catch((e) => {
        console.error("Failed to start P2P trade reconciler:", e);
    });

    // 2. Start Price Service (Candle Generator)
    try {
        priceService.start();
        console.log("Price Service started");
    } catch (e) {
        console.error("Failed to start Price Service:", e);
    }

    // 3. Request Keeper
    try {
        const requestKeeper = new RequestKeeper();
        requestKeeper.start();
        console.log("Request Keeper started");
    } catch (e) {
        console.error("Failed to start Request Keeper:", e);
    }

    // 4. Whale Stats Service (Copy Trading real followers/ROI/PnL)
    try {
        whaleStatsService.start();
        console.log("Whale Stats Service started");
    } catch (e) {
        console.error("Failed to start Whale Stats Service:", e);
    }

    // // 5. Liquidation Keeper

    // try {
    //     const keeper = new LiquidationKeeper();
    //     keeper.start();
    //     console.log("Liquidation Keeper started");
    // } catch (e) {
    //     console.error("Failed to start Liquidation Keeper:", e);
    // }

}).catch((error) => {
    console.error('Failed to connect to database:', error);
    process.exit(1);
});


app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});


// Start Blockchain Listeners
// BlockchainService.startEventListener().then(() => {
//     console.log("Blockchain Event Listeners active (P2P + CopyTrading)");
// }).catch((error) => {
//     console.error('Failed to start blockchain event listener:', error);
//     // Don't exit immediately, let it retry
//     console.log('Event listener will retry automatically...');
// });