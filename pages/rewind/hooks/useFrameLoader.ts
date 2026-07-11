import { useCallback, useRef, useState } from "react";

interface UseFrameLoaderOptions {
	port: number;
	apiKey: string;
	maxCacheSize?: number;
	maxQueueSize?: number;
	interRequestDelay?: number;
}

export function useFrameLoader({
	port,
	apiKey,
	maxCacheSize = 100,
	maxQueueSize = 3,
	interRequestDelay = 100
}: UseFrameLoaderOptions) {
	const [imageUrls, setImageUrls] = useState<Record<number, string>>({});
	const cachedIds = useRef(new Set<number>());
	const lruOrder = useRef<number[]>([]);
	const queue = useRef<number[]>([]);
	const processing = useRef(false);
	const [loadingFrameId, setLoadingFrameId] = useState<number | null>(null);

	const processQueue = useCallback(async () => {
		if (port < 0 || processing.current || queue.current.length === 0) return;

		processing.current = true;
		const frameId = queue.current.shift()!;

		// Skip if already cached
		if (cachedIds.current.has(frameId)) {
			processing.current = false;
			setTimeout(() => processQueue(), 0);
			return;
		}

		setLoadingFrameId(frameId);

		try {
			const response = await fetch(`http://localhost:${port}/frame/${frameId}`, {
				headers: { "x-api-key": apiKey }
			});
			const blob = await response.blob();
			const url = URL.createObjectURL(blob);

			// Update LRU order
			const idx = lruOrder.current.indexOf(frameId);
			if (idx !== -1) lruOrder.current.splice(idx, 1);
			lruOrder.current.push(frameId);
			cachedIds.current.add(frameId);

			// Evict old entries
			const toRevoke: number[] = [];
			while (lruOrder.current.length > maxCacheSize) {
				const evicted = lruOrder.current.shift()!;
				cachedIds.current.delete(evicted);
				toRevoke.push(evicted);
			}

			setImageUrls((prev) => {
				const next = { ...prev, [frameId]: url };
				for (const id of toRevoke) {
					if (next[id]) {
						URL.revokeObjectURL(next[id]);
						delete next[id];
					}
				}
				return next;
			});
		} catch (error) {
			console.error("Failed to load frame:", error);
		} finally {
			setLoadingFrameId(null);
			processing.current = false;
			setTimeout(() => processQueue(), interRequestDelay);
		}
	}, [port, apiKey, interRequestDelay, maxCacheSize]);

	const loadFrame = useCallback(
		(frameId: number) => {
			if (port < 0 || cachedIds.current.has(frameId)) return;

			if (!queue.current.includes(frameId)) {
				queue.current.push(frameId);
				queue.current = queue.current.slice(-maxQueueSize);
			}

			if (!processing.current) {
				processQueue();
			}
		},
		[port, processQueue, maxQueueSize]
	);

	return { imageUrls, loadFrame, loadingFrameId };
}
