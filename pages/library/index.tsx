import { useTranslation } from "react-i18next";
import { useCallback, useEffect, useState } from "react";
import { useAtomValue } from "jotai";
import { apiInfoAtom } from "../../src/renderer/state/apiInfo.ts";
import "./index.css";

interface StatusActivity {
	key: string;
	count?: number;
}

interface FileEntry {
	name: string;
	size: number;
	createdAt: number;
}

interface LibraryStats {
	videos: {
		path: string;
		files: FileEntry[];
		totalSize: number;
		count: number;
	};
	audio: {
		path: string;
		files: FileEntry[];
		totalSize: number;
		count: number;
	};
	database: {
		path: string;
		size: number;
	};
	totalSize: number;
}

function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B";
	const units = ["B", "KB", "MB", "GB"];
	const i = Math.floor(Math.log(bytes) / Math.log(1024));
	const value = bytes / Math.pow(1024, i);
	return `${value.toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}

function formatDate(timestamp: number): string {
	const date = new Date(timestamp);
	const now = new Date();
	const isToday = date.toDateString() === now.toDateString();
	if (isToday) {
		return date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
	}
	return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function showFrame() {
	return navigator.userAgent.includes("Mac");
}

/* ── Icons ────────────────────────────────────────── */

function FolderIcon() {
	return (
		<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className="opacity-50">
			<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
		</svg>
	);
}

function VideoIcon() {
	return (
		<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-gray-400 dark:text-gray-500">
			<rect x="2" y="2" width="20" height="20" rx="2.18" ry="2.18" />
			<path d="m7 2 0 20" />
			<path d="m17 2 0 20" />
			<path d="m2 12 20 0" />
			<path d="m2 7 5 0" />
			<path d="m2 17 5 0" />
			<path d="m17 17 5 0" />
			<path d="m17 7 5 0" />
		</svg>
	);
}

function AudioIcon() {
	return (
		<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-gray-400 dark:text-gray-500">
			<path d="M9 18V5l12-2v13" />
			<circle cx="6" cy="18" r="3" />
			<circle cx="18" cy="16" r="3" />
		</svg>
	);
}

function DatabaseIcon() {
	return (
		<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-gray-400 dark:text-gray-500">
			<ellipse cx="12" cy="5" rx="9" ry="3" />
			<path d="M21 12c0 1.66-4.03 3-9 3s-9-1.34-9-3" />
			<path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5" />
		</svg>
	);
}

/* ── Title Bar ────────────────────────────────────── */

function TitleBar() {
	const { t } = useTranslation();
	if (showFrame()) {
		return (
			<div className="w-full flex items-center justify-center h-12 glass-titlebar" id="title-bar">
				<span className="text-[13px] font-medium text-gray-700 dark:text-gray-200">
					{t("library.title")}
				</span>
			</div>
		);
	}
	return (
		<div className="w-full h-12 glass-titlebar relative">
			<div className="w-[calc(100%-44px)] h-12 absolute left-[22px] flex justify-center" id="title-bar">
				<span className="self-center text-[13px] font-medium text-gray-700 dark:text-gray-200">
					{t("library.title")}
				</span>
			</div>
			<div
				className="z-50 absolute right-3 top-3.5 bg-red-500 hover:bg-rose-400 h-3 w-3 rounded-full cursor-default"
				onClick={() => window.libraryWindow.close()}
			>
				<svg className="hover:opacity-100 opacity-0" xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24">
					<path fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="2" d="m8.464 15.535l7.072-7.07m-7.072 0l7.072 7.07" />
				</svg>
			</div>
		</div>
	);
}

/* ── Status Bar ────────────────────────────────────── */

function StatusBar({ activities }: { activities: StatusActivity[] }) {
	const { t } = useTranslation();
	if (activities.length === 0) return null;

	const labels: Record<string, (a: StatusActivity) => string> = {
		"encoding": () => t("library.status-encoding"),
		"frames-waiting": (a) => t("library.status-frames-waiting", { count: a.count }),
		"transcribing": () => t("library.status-transcribing"),
		"audio-waiting": (a) => t("library.status-audio-waiting", { count: a.count })
	};

	const isActive = activities.some((a) => a.key === "encoding" || a.key === "transcribing");

	return (
		<div className="flex items-center gap-2 px-1">
			{isActive && (
				<div className="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse shrink-0" />
			)}
			<p className="text-[11px] text-gray-400 dark:text-gray-500">
				{activities.map((a) => labels[a.key]?.(a) || a.key).join(" · ")}
			</p>
		</div>
	);
}

/* ── Storage Overview ─────────────────────────────── */

function StorageOverview({ stats }: { stats: LibraryStats }) {
	const { t } = useTranslation();
	const total = stats.totalSize;
	if (total === 0) return null;

	const segments = [
		{ label: t("library.screen-recordings"), size: stats.videos.totalSize, color: "bg-blue-400 dark:bg-blue-500" },
		{ label: t("library.audio-recordings"), size: stats.audio.totalSize, color: "bg-teal-400 dark:bg-teal-500" },
		{ label: t("library.database"), size: stats.database.size, color: "bg-orange-300 dark:bg-amber-500" }
	];

	return (
		<div className="glass rounded-2xl p-5">
			<div className="flex items-baseline justify-between mb-4">
				<span className="text-[11px] font-semibold uppercase tracking-wider text-gray-400 dark:text-gray-500">
					{t("library.storage-overview")}
				</span>
				<span className="text-[22px] font-semibold tracking-tight text-gray-800 dark:text-white">
					{formatBytes(total)}
				</span>
			</div>

			{/* Bar */}
			<div className="storage-bar w-full h-2 rounded-full flex gap-[2px]">
				{segments.map((seg) => {
					const pct = (seg.size / total) * 100;
					if (pct < 0.5) return null;
					return (
						<div
							key={seg.label}
							className={`h-full first:rounded-l-full last:rounded-r-full ${seg.color}`}
							style={{ width: `${pct}%` }}
						/>
					);
				})}
			</div>

			{/* Legend */}
			<div className="flex gap-5 mt-3">
				{segments.map((seg) => (
					<div key={seg.label} className="flex items-center gap-1.5">
						<div className={`w-2 h-2 rounded-full ${seg.color}`} />
						<span className="text-[11px] text-gray-500 dark:text-gray-400">
							{seg.label}
						</span>
						<span className="text-[11px] font-medium text-gray-700 dark:text-gray-300">
							{formatBytes(seg.size)}
						</span>
					</div>
				))}
			</div>
		</div>
	);
}

/* ── File Section ─────────────────────────────────── */

function TrashIcon() {
	return (
		<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="text-gray-300 dark:text-gray-600 opacity-0 group-hover:opacity-100 hover:!text-red-400 transition-all cursor-default">
			<polyline points="3 6 5 6 21 6" />
			<path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
		</svg>
	);
}

function FileSection({
	title,
	icon,
	files,
	totalSize,
	count,
	folderPath,
	fileType,
	port,
	apiKey,
	onRefresh
}: {
	title: string;
	icon: React.ReactNode;
	files: FileEntry[];
	totalSize: number;
	count: number;
	folderPath: string;
	fileType: "video" | "audio";
	port: number;
	apiKey: string;
	onRefresh: () => void;
}) {
	const { t } = useTranslation();
	const deleteFile = async (filename: string) => {
		try {
			await fetch(`http://localhost:${port}/library/file`, {
				method: "DELETE",
				headers: { "x-api-key": apiKey, "Content-Type": "application/json" },
				body: JSON.stringify({ type: fileType, filename })
			});
			onRefresh();
		} catch (err) {
			console.error("Failed to delete file:", err);
		}
	};

	const countLabel = count === 0
		? t("library.no-files")
		: count === 1
			? t("library.file-singular")
			: t("library.files", { count });

	return (
		<div className="glass rounded-2xl overflow-hidden">
			{/* Section header */}
			<div className="flex items-center justify-between px-5 py-3.5">
				<div className="flex items-center gap-2.5">
					{icon}
					<span className="text-[13px] font-semibold text-gray-800 dark:text-white">{title}</span>
					<span className="text-[11px] text-gray-400 dark:text-gray-500">
						{countLabel} &middot; {formatBytes(totalSize)}
					</span>
				</div>
				<button
					onClick={() => window.libraryWindow.openFolder(folderPath)}
					className="glass-btn p-1.5 rounded-lg
						text-gray-500 dark:text-gray-400
						flex items-center"
					title={t("library.open-in-finder")}
				>
					<FolderIcon />
				</button>
			</div>

			{/* File list */}
			{files.length > 0 ? (
				<div>
					<div className="glass-separator" />
					{files.slice(0, 15).map((file, i) => (
						<div key={file.name}>
							{i > 0 && <div className="glass-separator mx-5" />}
							<div className="glass-row group flex items-center justify-between px-5 py-2">
								<span className="text-[12px] text-gray-700 dark:text-gray-300 truncate max-w-[290px] font-mono">
									{file.name}
								</span>
								<div className="flex items-center gap-4 shrink-0">
									<span className="text-[11px] text-gray-400 dark:text-gray-500 tabular-nums w-16 text-right">
										{formatBytes(file.size)}
									</span>
									<span className="text-[11px] text-gray-400 dark:text-gray-500 tabular-nums w-14 text-right">
										{formatDate(file.createdAt)}
									</span>
									<div onClick={() => deleteFile(file.name)} className="w-4 flex justify-center">
										<TrashIcon />
									</div>
								</div>
							</div>
						</div>
					))}
					{count > 15 && (
						<>
							<div className="glass-separator" />
							<div className="text-center text-[11px] text-gray-400 dark:text-gray-500 py-2">
								+{count - 15} more
							</div>
						</>
					)}
				</div>
			) : (
				<>
					<div className="glass-separator" />
					<div className="text-center py-8 text-[12px] text-gray-400 dark:text-gray-500">
						{t("library.no-files")}
					</div>
				</>
			)}
		</div>
	);
}

/* ── Transcriptions Section ────────────────────────── */

interface TranscriptionEntry {
	id: number;
	text: string;
	language: string | null;
	timestamp: number;
	chunkId: number;
}

function TranscriptIcon() {
	return (
		<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-gray-400 dark:text-gray-500">
			<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
		</svg>
	);
}

function CopyButton({ text }: { text: string }) {
	const [copied, setCopied] = useState(false);
	return (
		<div
			onClick={() => {
				navigator.clipboard.writeText(text);
				setCopied(true);
				setTimeout(() => setCopied(false), 1500);
			}}
			className="w-4 flex justify-center cursor-default"
		>
			{copied ? (
				<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="text-green-500">
					<polyline points="20 6 9 17 4 12" />
				</svg>
			) : (
				<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="text-gray-300 dark:text-gray-600 opacity-0 group-hover:opacity-100 hover:!text-blue-400 transition-all">
					<rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
					<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
				</svg>
			)}
		</div>
	);
}

function TranscriptionsSection({
	transcriptions,
	totalCount,
	port,
	apiKey,
	onRefresh
}: {
	transcriptions: TranscriptionEntry[];
	totalCount: number;
	port: number;
	apiKey: string;
	onRefresh: () => void;
}) {
	const { t } = useTranslation();

	const deleteTranscription = async (id: number) => {
		try {
			await fetch(`http://localhost:${port}/library/transcription/${id}`, {
				method: "DELETE",
				headers: { "x-api-key": apiKey }
			});
			onRefresh();
		} catch (err) {
			console.error("Failed to delete transcription:", err);
		}
	};

	const [copied, setCopied] = useState(false);

	const copyAll = async () => {
		try {
			const res = await fetch(`http://localhost:${port}/library/transcriptions?limit=10000`, {
				headers: { "x-api-key": apiKey }
			});
			const data = await res.json();
			const text = [...data.transcriptions].reverse().map((tr: TranscriptionEntry) => tr.text).join("\n");
			await navigator.clipboard.writeText(text);
		} catch {
			// Fallback to loaded transcriptions (reverse to chronological order)
			await navigator.clipboard.writeText([...transcriptions].reverse().map((tr) => tr.text).join("\n"));
		}
		setCopied(true);
		setTimeout(() => setCopied(false), 1500);
	};

	const countLabel = totalCount === 0
		? t("library.no-transcriptions")
		: t("library.transcriptions-count", { count: totalCount });

	return (
		<div className="glass rounded-2xl overflow-hidden">
			<div className="flex items-center justify-between px-5 py-3.5">
				<div className="flex items-center gap-2.5">
					<TranscriptIcon />
					<span className="text-[13px] font-semibold text-gray-800 dark:text-white">
						{t("library.transcriptions")}
					</span>
					<span className="text-[11px] text-gray-400 dark:text-gray-500">
						{countLabel}
					</span>
				</div>
				{transcriptions.length > 0 && (
					<button
						onClick={copyAll}
						className="glass-btn p-1.5 rounded-lg
							text-gray-500 dark:text-gray-400
							flex items-center"
						title={t("library.copy-all")}
					>
						{copied ? (
							<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="text-green-500">
								<polyline points="20 6 9 17 4 12" />
							</svg>
						) : (
							<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" className="opacity-50">
								<rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
								<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
							</svg>
						)}
					</button>
				)}
			</div>

			{transcriptions.length > 0 ? (
				<div>
					<div className="glass-separator" />
					{transcriptions.slice(0, 20).map((tr, i) => (
						<div key={tr.id}>
							{i > 0 && <div className="glass-separator mx-5" />}
							<div className="glass-row group flex items-start justify-between px-5 py-2.5 gap-3">
								<div className="flex-1 min-w-0">
									<p className="text-[12px] text-gray-700 dark:text-gray-300 leading-relaxed line-clamp-2">
										{tr.text}
									</p>
									<div className="flex items-center gap-2 mt-1">
										<span className="text-[10px] text-gray-400 dark:text-gray-500 tabular-nums">
											{formatDate(tr.timestamp)}
										</span>
										{tr.language && (
											<span className="text-[10px] text-gray-400 dark:text-gray-500 uppercase">
												{tr.language}
											</span>
										)}
									</div>
								</div>
								<div className="flex items-center gap-2 shrink-0 pt-0.5">
									<CopyButton text={tr.text} />
									<div onClick={() => deleteTranscription(tr.id)} className="w-4 flex justify-center">
										<TrashIcon />
									</div>
								</div>
							</div>
						</div>
					))}
					{totalCount > 20 && (
						<>
							<div className="glass-separator" />
							<div className="text-center text-[11px] text-gray-400 dark:text-gray-500 py-2">
								+{totalCount - 20} more
							</div>
						</>
					)}
				</div>
			) : (
				<>
					<div className="glass-separator" />
					<div className="text-center py-8 text-[12px] text-gray-400 dark:text-gray-500">
						{t("library.no-transcriptions")}
					</div>
				</>
			)}
		</div>
	);
}

/* ── Database Section ─────────────────────────────── */

function DatabaseSection({ stats }: { stats: LibraryStats }) {
	const { t } = useTranslation();
	return (
		<div className="glass rounded-2xl overflow-hidden">
			<div className="flex items-center justify-between px-5 py-3.5">
				<div className="flex items-center gap-2.5">
					<DatabaseIcon />
					<span className="text-[13px] font-semibold text-gray-800 dark:text-white">
						{t("library.database")}
					</span>
					<span className="text-[11px] text-gray-400 dark:text-gray-500">
						{formatBytes(stats.database.size)}
					</span>
				</div>
				<button
					onClick={() => {
						const dbDir = stats.database.path.split("/").slice(0, -1).join("/");
						window.libraryWindow.openFolder(dbDir);
					}}
					className="glass-btn p-1.5 rounded-lg
						text-gray-500 dark:text-gray-400
						flex items-center"
					title={t("library.open-in-finder")}
				>
					<FolderIcon />
				</button>
			</div>
		</div>
	);
}

/* ── Main Page ────────────────────────────────────── */

export default function LibraryPage() {
	const { t } = useTranslation();
	const { port, apiKey } = useAtomValue(apiInfoAtom);
	const [stats, setStats] = useState<LibraryStats | null>(null);
	const [activities, setActivities] = useState<StatusActivity[]>([]);
	const [transcriptions, setTranscriptions] = useState<TranscriptionEntry[]>([]);
	const [transcriptionCount, setTranscriptionCount] = useState(0);
	const [loading, setLoading] = useState(true);

	const fetchStats = useCallback(async () => {
		if (port < 0) return;
		try {
			const res = await fetch(`http://localhost:${port}/library/stats`, {
				headers: { "x-api-key": apiKey }
			});
			setStats(await res.json());
		} catch (err) {
			console.error("Failed to fetch library stats:", err);
		} finally {
			setLoading(false);
		}
	}, [port, apiKey]);

	const fetchTranscriptions = useCallback(async () => {
		if (port < 0) return;
		try {
			const res = await fetch(`http://localhost:${port}/library/transcriptions?limit=30`, {
				headers: { "x-api-key": apiKey }
			});
			const data = await res.json();
			setTranscriptions(data.transcriptions);
			setTranscriptionCount(data.count);
		} catch {}
	}, [port, apiKey]);

	const fetchStatus = useCallback(async () => {
		if (port < 0) return;
		try {
			const res = await fetch(`http://localhost:${port}/library/status`, {
				headers: { "x-api-key": apiKey }
			});
			const data = await res.json();
			setActivities(data.activities);
		} catch {}
	}, [port, apiKey]);

	const fetchAll = useCallback(() => {
		fetchStats();
		fetchTranscriptions();
		fetchStatus();
	}, [fetchStats, fetchTranscriptions, fetchStatus]);

	// Fetch on mount
	useEffect(() => {
		fetchAll();
	}, [fetchAll]);

	// Poll status every 3 seconds while window is visible
	useEffect(() => {
		const interval = setInterval(fetchStatus, 3000);
		return () => clearInterval(interval);
	}, [fetchStatus]);

	// Re-fetch when window becomes visible (user reopens library)
	useEffect(() => {
		const onFocus = () => fetchAll();
		window.addEventListener("focus", onFocus);
		return () => window.removeEventListener("focus", onFocus);
	}, [fetchAll]);

	return (
		<>
			<title>{t("library.title")}</title>
			{/* Glass title bar */}
			<div className="w-full h-auto flex flex-col fixed z-10">
				<TitleBar />
			</div>

			{/* Content */}
			<div
				className="h-full w-full bg-gray-50/80 dark:bg-[#1a1a1e] library-bg
					relative pt-14 pb-6 px-6 overflow-auto"
				id="library-scroll-container"
			>
				{loading ? (
					<div className="flex items-center justify-center h-48">
						<div className="text-[13px] text-gray-400 dark:text-gray-500">Loading...</div>
					</div>
				) : stats ? (
					<div className="flex flex-col gap-4">
						<StatusBar activities={activities} />
						<StorageOverview stats={stats} />

						<FileSection
							title={t("library.screen-recordings")}
							icon={<VideoIcon />}
							files={stats.videos.files}
							totalSize={stats.videos.totalSize}
							count={stats.videos.count}
							folderPath={stats.videos.path}
							fileType="video"
							port={port}
							apiKey={apiKey}
							onRefresh={fetchAll}
						/>

						<FileSection
							title={t("library.audio-recordings")}
							icon={<AudioIcon />}
							files={stats.audio.files}
							totalSize={stats.audio.totalSize}
							count={stats.audio.count}
							folderPath={stats.audio.path}
							fileType="audio"
							port={port}
							apiKey={apiKey}
							onRefresh={fetchAll}
						/>

						<TranscriptionsSection
							transcriptions={transcriptions}
							totalCount={transcriptionCount}
							port={port}
							apiKey={apiKey}
							onRefresh={fetchTranscriptions}
						/>

						<DatabaseSection stats={stats} />

						<p className="text-center text-[11px] text-gray-400/70 dark:text-gray-600 pt-1 pb-2">
							{t("library.retention-note")}
						</p>
					</div>
				) : (
					<div className="flex items-center justify-center h-48">
						<div className="text-[13px] text-gray-400 dark:text-gray-500">Failed to load library data.</div>
					</div>
				)}
			</div>
		</>
	);
}
