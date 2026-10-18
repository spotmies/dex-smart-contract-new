import express from 'express';
import { createTrade, getTradesByAddress } from '../controllers/PerpTradeController.js';
import { protect } from '../middleware/authMiddleware.js';
import { csrfProtection } from '../middleware/csrfMiddleware.js';

const router = express.Router();

router.post('/trade', protect, csrfProtection, createTrade);
router.get('/trades/:walletAddress', protect, getTradesByAddress);

export default router;
