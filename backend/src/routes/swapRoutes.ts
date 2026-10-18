import express from 'express';
import { storeSwap, getSwapsByUser } from '../controllers/swapController.js';
import { protect } from '../middleware/authMiddleware.js';
import { csrfProtection } from '../middleware/csrfMiddleware.js';

const router = express.Router();

router.post('/', protect, csrfProtection, storeSwap);
router.get('/:userAddress', protect, getSwapsByUser);

export default router;
