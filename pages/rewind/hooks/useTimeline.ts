import { useCallback, useEffect, useRef, useState } from "react";
import type { Frame } from "../../../src/electron/backend/schema.d.ts";

interface UseTimelineOptions {
	port: number;
	apiKey: string;
}

export function useTimeline({ port, apiKey }: UseTimelineOptions) {
	const [timeline, setTimeline] = useState<Frame[]>([]);
	const [currentIndex, setCurrentIndex] = useState(0);
	const [isLoadingMore, setIsLoadingMore] = useState(false);
	const timelineRef = useRef<Frame[]>([]);

	// Keep ref in sync for use in callbacks
	useEffect(() => {
		timelineRef.current = timeline;
	}, [timeline]);

	const fetchTimeline = useCallback(
		async (untilID?: number) => {
			if (port < 0) return;
			try {
				const url = new URL(`http://localhost:${port}/timeline`);
				if (untilID) url.searchParams.set("untilID", untilID.toString());

				const response = await fetch(url.toString(), {
					headers: { "x-api-key": apiKey }
				});
				const data: Frame[] = await response.json();
				setTimeline((prev) => (untilID ? [...prev, ...data] : data));
			} catch (error) {
				console.error("Failed to fetch timeline:", error);
			}
		},
		[port, apiKey]
	);

	// Initial fetch + refresh when window becomes visible
	useEffect(() => {
		fetchTimeline();

		const handleVisibilityChange = () => {
			if (document.visibilityState === "visible") {
				setCurrentIndex(0);
				fetchTimeline();
			}
		};
		document.addEventListener("visibilitychange", handleVisibilityChange);
		return () => document.removeEventListener("visibilitychange", handleVisibilityChange);
	}, [fetchTimeline]);

	// Load more when near end
	useEffect(() => {
		if (currentIndex > timeline.length - 10 && !isLoadingMore && timeline.length > 0) {
			setIsLoadingMore(true);
			const lastID = timeline[timeline.length - 1].id;
			fetchTimeline(lastID).finally(() => setIsLoadingMore(false));
		}
	}, [currentIndex, timeline, isLoadingMore, fetchTimeline]);

	const navigate = useCallback(
		(delta: number) => {
			setCurrentIndex((prev) => {
				const len = timelineRef.current.length;
				if (len === 0) return prev;
				return Math.max(0, Math.min(prev + delta, len - 1));
			});
		},
		[]
	);

	const jumpToIndex = useCallback(
		(index: number) => {
			setCurrentIndex(Math.max(0, Math.min(index, timelineRef.current.length - 1)));
		},
		[]
	);

	const jumpToFrameId = useCallback(
		(frameId: number) => {
			const idx = timelineRef.current.findIndex((f) => f.id === frameId);
			if (idx !== -1) setCurrentIndex(idx);
		},
		[]
	);

	const jumpToTimestamp = useCallback(
		(timestamp: number) => {
			const tl = timelineRef.current;
			if (tl.length === 0) return;

			let closestIdx = 0;
			let closestDiff = Infinity;
			for (let i = 0; i < tl.length; i++) {
				const diff = Math.abs(tl[i].createdAt - timestamp);
				if (diff < closestDiff) {
					closestDiff = diff;
					closestIdx = i;
				}
			}
			setCurrentIndex(closestIdx);
		},
		[]
	);

	const currentFrame = timeline[currentIndex] || null;

	return {
		timeline,
		currentIndex,
		currentFrame,
		navigate,
		jumpToIndex,
		jumpToFrameId,
		jumpToTimestamp,
		isLoadingMore
	};
}
