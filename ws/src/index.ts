import express from "express";
import { Server } from "socket.io";
import http from "http";
import dotenv from "dotenv";
import mongoose from "mongoose";
import cors from "cors";
import jwt from "jsonwebtoken";

dotenv.config();

// ---------------------------------------------------------------------------------------------------------------
// Config. Fail fast: a chat server that starts without these would silently accept everyone (P2P-02).
// ---------------------------------------------------------------------------------------------------------------
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET.length < 32) {
    throw new Error("JWT_SECRET must be set (>= 32 chars) and be the same value the backend signs sessions with.");
}

// Must match the backend's cookie name (backend/src/utils/authCookie.ts -> ACCESS_COOKIE).
const ACCESS_COOKIE = "access";

const CORS_ORIGINS = (process.env.CORS_ORIGINS || "http://localhost:8080,http://localhost:5173")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);

const MAX_MESSAGE_LENGTH = 1000;
const RATE_WINDOW_MS = 10_000;
const RATE_MAX_MESSAGES = 10;

const app = express();
app.use(cors({ origin: CORS_ORIGINS, credentials: true }));
app.get("/health", (_req, res) => {
    res.json({ ok: true });
});

const server = http.createServer(app);
const io = new Server(server, {
    cors: { origin: CORS_ORIGINS, methods: ["GET", "POST"], credentials: true },
    maxHttpBufferSize: 16 * 1024,
});

// ---------------------------------------------------------------------------------------------------------------
// Database: same MongoDB as the backend. Schemas are declared locally and must match the backend models.
// ---------------------------------------------------------------------------------------------------------------
const MONGO_URI = process.env.MONGO_URI || "mongodb://localhost:27017/p2p-escrow";

mongoose
    .connect(MONGO_URI)
    .then(() => console.log("WS Service Connected to MongoDB"))
    .catch((err) => console.error("MongoDB Connection Error:", err));

const ChatMessage = mongoose.model(
    "ChatMessage",
    new mongoose.Schema({
        purchaseId: { type: Number, required: true, index: true },
        sender: { type: String, required: true },
        message: { type: String, required: true },
        timestamp: { type: Date, default: Date.now },
    })
);

// Read-only views of backend collections (names resolve to `users` / `trades`, as in the backend).
const User = mongoose.model(
    "User",
    new mongoose.Schema({ walletAddress: String }, { strict: false })
);
const Trade = mongoose.model(
    "Trade",
    new mongoose.Schema({ purchaseId: Number, buyer: String, seller: String }, { strict: false })
);

// ---------------------------------------------------------------------------------------------------------------
// Authentication: verify the backend's session JWT at the handshake, before any event handler is attached.
// ---------------------------------------------------------------------------------------------------------------
function readCookie(header: string | undefined, name: string): string | undefined {
    if (!header) return undefined;
    for (const part of header.split(";")) {
        const idx = part.indexOf("=");
        if (idx === -1) continue;
        if (part.slice(0, idx).trim() === name) {
            try {
                return decodeURIComponent(part.slice(idx + 1).trim());
            } catch {
                return undefined;
            }
        }
    }
    return undefined;
}

interface SocketData {
    wallet: string; // lower-case address from the verified user record, never from the client
    exp: number; // JWT expiry, epoch seconds
    rooms: Set<number>; // trades this socket has been authorised to use
    sent: number[]; // timestamps of recent messages (rate limit)
}

io.use(async (socket, next) => {
    try {
        let token = readCookie(socket.handshake.headers.cookie, ACCESS_COOKIE);
        // Mobile / non-browser clients can pass the token explicitly instead of a cookie.
        const authToken = (socket.handshake.auth as { token?: unknown } | undefined)?.token;
        if (!token && typeof authToken === "string") token = authToken.replace(/^Bearer\s+/i, "");
        if (!token) return next(new Error("unauthorized"));

        const decoded = jwt.verify(token, JWT_SECRET, { clockTolerance: 5 }) as { id?: string; exp?: number };
        if (!decoded.id || !decoded.exp) return next(new Error("unauthorized"));

        const user = await User.findById(decoded.id).select("walletAddress").lean<{ walletAddress?: string }>();
        if (!user?.walletAddress) return next(new Error("unauthorized"));

        const data: SocketData = {
            wallet: user.walletAddress.toLowerCase(),
            exp: decoded.exp,
            rooms: new Set(),
            sent: [],
        };
        socket.data = data;
        next();
    } catch {
        next(new Error("unauthorized"));
    }
});

function parsePurchaseId(value: unknown): number | null {
    const n = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
    return typeof n === "number" && Number.isSafeInteger(n) && n >= 0 ? n : null;
}

const isExpired = (data: SocketData) => Date.now() / 1000 >= data.exp;

io.on("connection", (socket) => {
    const data = socket.data as SocketData;

    socket.on("join_room", async (payload: { purchaseId?: unknown }) => {
        try {
            const purchaseId = parsePurchaseId(payload?.purchaseId);
            if (purchaseId === null) return socket.emit("chat_error", { code: "bad_request" });
            if (isExpired(data)) return socket.emit("chat_error", { code: "session_expired" });

            // Only the buyer or the seller of this trade may read or write its chat.
            const trade = await Trade.findOne({ purchaseId }).lean<{ buyer?: string; seller?: string }>();
            const parties = [trade?.buyer, trade?.seller].map((a) => a?.toLowerCase());
            if (!trade || !parties.includes(data.wallet)) {
                return socket.emit("chat_error", { code: "forbidden" });
            }

            data.rooms.add(purchaseId);
            await socket.join(`trade-${purchaseId}`);

            const history = await ChatMessage.find({ purchaseId }).sort({ timestamp: 1 }).limit(100);
            socket.emit("chat_history", history);
        } catch (e) {
            console.error("join_room failed:", e instanceof Error ? e.message : e);
            socket.emit("chat_error", { code: "server_error" });
        }
    });

    socket.on("send_message", async (payload: { purchaseId?: unknown; message?: unknown }) => {
        try {
            const purchaseId = parsePurchaseId(payload?.purchaseId);
            if (purchaseId === null) return socket.emit("chat_error", { code: "bad_request" });
            if (isExpired(data)) return socket.emit("chat_error", { code: "session_expired" });
            if (!data.rooms.has(purchaseId)) return socket.emit("chat_error", { code: "forbidden" });

            const message = typeof payload?.message === "string" ? payload.message.trim() : "";
            if (!message || message.length > MAX_MESSAGE_LENGTH) {
                return socket.emit("chat_error", { code: "bad_message" });
            }

            const now = Date.now();
            data.sent = data.sent.filter((t) => now - t < RATE_WINDOW_MS);
            if (data.sent.length >= RATE_MAX_MESSAGES) return socket.emit("chat_error", { code: "rate_limited" });
            data.sent.push(now);

            // The sender is the authenticated wallet. Any `sender` the client supplies is ignored.
            const saved = await ChatMessage.create({
                purchaseId,
                sender: data.wallet,
                message,
                timestamp: new Date(),
            });
            io.to(`trade-${purchaseId}`).emit("receive_message", saved);
        } catch (e) {
            console.error("send_message failed:", e instanceof Error ? e.message : e);
            socket.emit("chat_error", { code: "server_error" });
        }
    });
});

const PORT = process.env.PORT || 3003;
server.listen(PORT, () => {
    console.log(`WebSocket Server running on port ${PORT}`);
});
