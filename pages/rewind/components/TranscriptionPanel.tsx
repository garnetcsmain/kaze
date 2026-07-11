import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import type { TranscriptionSegment } from "../hooks/useTranscriptions";

interface TranscriptionPanelProps {
	visible: boolean;
	transcriptions: TranscriptionSegment[];
	currentTimestamp: number | null;
	onJumpToTimestamp: (timestamp: number) => void;
}

export function TranscriptionPanel({
	visible,
	transcriptions,
	currentTimestamp,
	onJumpToTimestamp
}: TranscriptionPanelProps) {
	const { t } = useTranslation();
	const scrollRef = useRef<HTMLDivElement>(null);
	const activeRef = useRef<HTMLDivElement>(null);

	// Auto-scroll to keep active segment visible
	useEffect(() => {
		if (activeRef.current && scrollRef.current) {
			activeRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
		}
	}, [currentTimestamp]);

	if (!visible || transcriptions.length === 0) return null;

	function isActive(segment: TranscriptionSegment) {
		if (!currentTimestamp) return false;
		return currentTimestamp >= segment.timestamp && currentTimestamp <= segment.endTimestamp;
	}

	function formatSegmentTime(timestamp: number) {
		const d = new Date(timestamp * 1000);
		return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
	}

	return (
		<div className="absolute top-20 left-4 bottom-24 z-30 w-[300px]">
			<div className="rewind-glass-panel rounded-2xl h-full flex flex-col overflow-hidden">
				{/* Header */}
				<div className="px-4 py-3 border-b border-white/10 flex items-center gap-2 shrink-0">
					<svg
						className="w-4 h-4 text-white/50"
						fill="none"
						viewBox="0 0 24 24"
						stroke="currentColor"
						strokeWidth={2}
					>
						<path
							strokeLinecap="round"
							strokeLinejoin="round"
							d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"
						/>
					</svg>
					<span className="text-white/70 text-sm font-medium">
						{t("rewind.transcriptions")}
					</span>
				</div>

				{/* Segments */}
				<div ref={scrollRef} className="flex-1 overflow-y-auto px-2 py-2 rewind-scrollbar">
					{transcriptions.map((segment) => {
						const active = isActive(segment);
						return (
							<div
								key={segment.id}
								ref={active ? activeRef : undefined}
								className={`px-3 py-2 rounded-lg cursor-pointer transition-colors mb-1 ${
									active ? "bg-white/15" : "hover:bg-white/[0.08]"
								}`}
								onClick={() => onJumpToTimestamp(segment.timestamp)}
							>
								<div className="flex items-center gap-2 mb-1">
									<span className="text-white/30 text-[10px] tabular-nums">
										{formatSegmentTime(segment.timestamp)}
									</span>
									{segment.language && (
										<span className="text-[9px] text-white/20 uppercase px-1 py-0.5 rounded bg-white/5">
											{segment.language}
										</span>
									)}
								</div>
								<p className={`text-sm leading-relaxed ${active ? "text-white/90" : "text-white/60"}`}>
									{segment.text}
								</p>
							</div>
						);
					})}
				</div>
			</div>
		</div>
	);
}
