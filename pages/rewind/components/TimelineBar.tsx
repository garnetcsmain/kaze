import { useCallback, useRef, useEffect, useMemo } from "react";
import type { Frame } from "../../../src/electron/backend/schema.d.ts";
import dayjs from "dayjs";

interface TimelineBarProps {
	timeline: Frame[];
	currentIndex: number;
	onJumpToIndex: (index: number) => void;
}

export function TimelineBar({ timeline, currentIndex, onJumpToIndex }: TimelineBarProps) {
	const trackRef = useRef<HTMLDivElement>(null);
	const isDragging = useRef(false);

	const currentFrame = timeline[currentIndex];
	const progress = timeline.length > 1 ? currentIndex / (timeline.length - 1) : 0;

	// Evenly-spaced time labels along the track
	const timeLabels = useMemo(() => {
		if (timeline.length < 20) return [];

		const labels: { position: number; text: string }[] = [];
		const count = Math.min(5, Math.floor(timeline.length / 20));
		if (count < 1) return [];

		for (let i = 1; i <= count; i++) {
			const idx = Math.floor((i / (count + 1)) * timeline.length);
			const position = (idx / (timeline.length - 1)) * 100;
			labels.push({
				position,
				text: dayjs.unix(timeline[idx].createdAt).format("h:mm A")
			});
		}
		return labels;
	}, [timeline]);

	const getIndexFromClientX = useCallback(
		(clientX: number) => {
			if (!trackRef.current || timeline.length < 2) return null;
			const rect = trackRef.current.getBoundingClientRect();
			const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
			return Math.round(ratio * (timeline.length - 1));
		},
		[timeline.length]
	);

	const handleMouseDown = useCallback(
		(e: React.MouseEvent) => {
			isDragging.current = true;
			const idx = getIndexFromClientX(e.clientX);
			if (idx !== null) onJumpToIndex(idx);
		},
		[getIndexFromClientX, onJumpToIndex]
	);

	useEffect(() => {
		const handleMouseMove = (e: MouseEvent) => {
			if (!isDragging.current) return;
			const idx = getIndexFromClientX(e.clientX);
			if (idx !== null) onJumpToIndex(idx);
		};
		const handleMouseUp = () => {
			isDragging.current = false;
		};

		window.addEventListener("mousemove", handleMouseMove);
		window.addEventListener("mouseup", handleMouseUp);
		return () => {
			window.removeEventListener("mousemove", handleMouseMove);
			window.removeEventListener("mouseup", handleMouseUp);
		};
	}, [getIndexFromClientX, onJumpToIndex]);

	function formatTime(timestamp: number) {
		const d = dayjs.unix(timestamp);
		const diff = dayjs().diff(d, "second");

		if (diff < 60) return d.fromNow();
		if (diff < 3600) return d.fromNow();
		if (diff < 86400) return d.format("h:mm A");
		return d.format("ddd, MMM D · h:mm A");
	}

	if (timeline.length === 0) return null;

	return (
		<div className="absolute bottom-0 left-0 right-0 p-4 z-30">
			<div className="rewind-glass-bar rounded-2xl px-5 py-3 flex items-center gap-4">
				{/* Time display */}
				<div className="text-white text-sm font-medium whitespace-nowrap min-w-[160px]">
					{currentFrame ? formatTime(currentFrame.createdAt) : "Loading..."}
				</div>

				{/* Track */}
				<div
					ref={trackRef}
					className="flex-1 relative h-8 flex items-center cursor-pointer group"
					onMouseDown={handleMouseDown}
				>
					{/* Track background */}
					<div className="w-full h-1 rounded-full bg-white/20 group-hover:h-1.5 transition-all relative">
						{/* Progress fill */}
						<div
							className="h-full rounded-full bg-white/60"
							style={{ width: `${progress * 100}%` }}
						/>
					</div>

					{/* Scrubber handle */}
					<div
						className="absolute w-3 h-3 rounded-full bg-white shadow-lg -translate-x-1/2
							group-hover:w-4 group-hover:h-4 transition-all pointer-events-none"
						style={{ left: `${progress * 100}%` }}
					/>

					{/* Time labels */}
					{timeLabels.map((label, i) => (
						<span
							key={i}
							className="absolute -bottom-3 text-[10px] text-white/40 -translate-x-1/2 pointer-events-none"
							style={{ left: `${label.position}%` }}
						>
							{label.text}
						</span>
					))}
				</div>

				{/* Frame counter */}
				<span className="text-white/40 text-xs whitespace-nowrap tabular-nums">
					{currentIndex + 1}/{timeline.length}
				</span>
			</div>
		</div>
	);
}
