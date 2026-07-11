import "./index.css";
import { useCallback, useEffect, useRef, useState } from "react";
import { useAtomValue } from "jotai";
import { apiInfoAtom } from "src/renderer/state/apiInfo.ts";
import dayjs from "dayjs";
import relativeTime from "dayjs/plugin/relativeTime";
import localizedFormat from "dayjs/plugin/localizedFormat";
import updateLocale from "dayjs/plugin/updateLocale";

import { useTimeline } from "./hooks/useTimeline";
import { useFrameLoader } from "./hooks/useFrameLoader";
import { useSearch } from "./hooks/useSearch";
import { useTranscriptions } from "./hooks/useTranscriptions";
import { FrameDisplay } from "./components/FrameDisplay";
import { TimelineBar } from "./components/TimelineBar";
import { SearchBar } from "./components/SearchBar";
import { SearchResults } from "./components/SearchResults";
import { TranscriptionPanel } from "./components/TranscriptionPanel";
import type { SearchResult } from "./hooks/useSearch";

dayjs.extend(relativeTime);
dayjs.extend(localizedFormat);
dayjs.extend(updateLocale);
dayjs.updateLocale("en", {
	relativeTime: {
		future: "in %s",
		past: "%s ago",
		s: "%d seconds",
		m: "1 minute",
		mm: "%d minutes",
		h: "1 hour",
		hh: "%d hours",
		d: "1 day",
		dd: "%d days",
		M: "1 month",
		MM: "%d months",
		y: "1 year",
		yy: "%d years"
	}
});

export default function RewindPage() {
	const { port, apiKey } = useAtomValue(apiInfoAtom);
	const [searchVisible, setSearchVisible] = useState(false);
	const [transcriptVisible, setTranscriptVisible] = useState(false);
	const lastScrollTime = useRef(Date.now());

	const { timeline, currentIndex, currentFrame, navigate, jumpToIndex, jumpToFrameId, jumpToTimestamp } =
		useTimeline({ port, apiKey });

	const { imageUrls, loadFrame, loadingFrameId } = useFrameLoader({
		port,
		apiKey,
		maxCacheSize: 100,
		maxQueueSize: 3,
		interRequestDelay: 100
	});

	const { query, setQuery, results, isSearching } = useSearch({ port, apiKey });

	const { transcriptions } = useTranscriptions({
		port,
		apiKey,
		currentTimestamp: currentFrame?.createdAt || null
	});

	// Load current and adjacent frames
	useEffect(() => {
		if (!currentFrame) return;
		loadFrame(currentFrame.id);

		// Preload adjacent
		if (currentIndex > 0) loadFrame(timeline[currentIndex - 1].id);
		if (currentIndex < timeline.length - 1) loadFrame(timeline[currentIndex + 1].id);
	}, [currentFrame, currentIndex, timeline, loadFrame]);

	// Resolve display URLs
	const currentUrl = currentFrame ? imageUrls[currentFrame.id] || null : null;

	// Find nearest loaded frame as fallback
	let fallbackUrl: string | null = null;
	if (!currentUrl && currentFrame) {
		for (let offset = 1; offset <= 5; offset++) {
			const prevIdx = currentIndex - offset;
			const nextIdx = currentIndex + offset;
			if (prevIdx >= 0 && imageUrls[timeline[prevIdx].id]) {
				fallbackUrl = imageUrls[timeline[prevIdx].id];
				break;
			}
			if (nextIdx < timeline.length && imageUrls[timeline[nextIdx].id]) {
				fallbackUrl = imageUrls[timeline[nextIdx].id];
				break;
			}
		}
	}

	// Keyboard controls
	useEffect(() => {
		const handleKeyDown = (e: KeyboardEvent) => {
			// When search input is focused, only handle Escape
			if (searchVisible && document.activeElement?.tagName === "INPUT") {
				return; // Let SearchBar handle its own keyboard events
			}

			switch (e.key) {
				case "ArrowLeft":
					e.preventDefault();
					navigate(e.shiftKey ? -10 : -1);
					break;
				case "ArrowRight":
					e.preventDefault();
					navigate(e.shiftKey ? 10 : 1);
					break;
				case "t":
				case "T":
					if (!searchVisible) {
						setTranscriptVisible((v) => !v);
					}
					break;
				case "f":
					if (e.metaKey || e.ctrlKey) {
						e.preventDefault();
						setSearchVisible(true);
					}
					break;
				case "/":
					if (!searchVisible) {
						e.preventDefault();
						setSearchVisible(true);
					}
					break;
				case "Escape":
					if (searchVisible) {
						setSearchVisible(false);
						setQuery("");
					}
					break;
			}
		};

		window.addEventListener("keydown", handleKeyDown);
		return () => window.removeEventListener("keydown", handleKeyDown);
	}, [searchVisible, navigate, setQuery]);

	// Mouse wheel scrolling
	const handleWheel = useCallback(
		(e: React.WheelEvent) => {
			const now = Date.now();
			if (now - lastScrollTime.current < 30) return;
			lastScrollTime.current = now;

			const delta = Math.sign(e.deltaY);
			navigate(-delta);
		},
		[navigate]
	);

	// Jump to search result
	const handleSearchJump = useCallback(
		(result: SearchResult) => {
			if (result.frameID) {
				jumpToFrameId(result.frameID);
			} else if (result.createdAt) {
				jumpToTimestamp(result.createdAt);
			}
			setSearchVisible(false);
			setQuery("");
		},
		[jumpToFrameId, jumpToTimestamp, setQuery]
	);

	return (
		<div
			className="w-screen h-screen relative dark:text-white overflow-hidden bg-black"
			onWheel={handleWheel}
		>
			{/* macOS title bar drag region */}
			<div className="absolute top-0 left-0 right-0 h-8 z-50 rewind-titlebar-drag" />

			{/* Layer 0 + 1: Frame display */}
			<FrameDisplay
				currentUrl={currentUrl}
				fallbackUrl={fallbackUrl}
				isLoading={loadingFrameId === currentFrame?.id}
			/>

			{/* Layer 2: HUD overlay */}

			{/* Search */}
			<SearchBar
				visible={searchVisible}
				query={query}
				onQueryChange={setQuery}
				onClose={() => {
					setSearchVisible(false);
					setQuery("");
				}}
				resultCount={results.length}
				isSearching={isSearching}
			/>
			<SearchResults
				results={results}
				visible={searchVisible && results.length > 0}
				onJumpToResult={handleSearchJump}
			/>

			{/* Transcription panel */}
			<TranscriptionPanel
				visible={transcriptVisible}
				transcriptions={transcriptions}
				currentTimestamp={currentFrame?.createdAt || null}
				onJumpToTimestamp={jumpToTimestamp}
			/>

			{/* Timeline bar */}
			<TimelineBar
				timeline={timeline}
				currentIndex={currentIndex}
				onJumpToIndex={jumpToIndex}
			/>
		</div>
	);
}
