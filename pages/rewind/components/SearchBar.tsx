import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";

interface SearchBarProps {
	visible: boolean;
	query: string;
	onQueryChange: (q: string) => void;
	onClose: () => void;
	resultCount: number;
	isSearching: boolean;
}

export function SearchBar({ visible, query, onQueryChange, onClose, resultCount, isSearching }: SearchBarProps) {
	const { t } = useTranslation();
	const inputRef = useRef<HTMLInputElement>(null);

	useEffect(() => {
		if (visible) {
			// Small delay to avoid capturing the triggering keypress
			setTimeout(() => inputRef.current?.focus(), 50);
		}
	}, [visible]);

	if (!visible) return null;

	const handleKeyDown = (e: React.KeyboardEvent) => {
		if (e.key === "Escape") {
			e.stopPropagation();
			if (query) {
				onQueryChange("");
			} else {
				onClose();
			}
		}
	};

	return (
		<div className="absolute top-6 left-1/2 -translate-x-1/2 z-40 w-[500px]">
			<div className="rewind-glass-input rounded-2xl px-4 py-3 flex items-center gap-3">
				{/* Magnifying glass icon */}
				<svg
					className="w-4 h-4 text-white/50 shrink-0"
					fill="none"
					viewBox="0 0 24 24"
					stroke="currentColor"
					strokeWidth={2}
				>
					<path
						strokeLinecap="round"
						strokeLinejoin="round"
						d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
					/>
				</svg>

				<input
					ref={inputRef}
					type="text"
					value={query}
					onChange={(e) => onQueryChange(e.target.value)}
					onKeyDown={handleKeyDown}
					placeholder={t("rewind.search-placeholder")}
					className="flex-1 bg-transparent text-white text-sm outline-none placeholder-white/30"
				/>

				{isSearching && (
					<div className="rewind-spinner-sm" />
				)}

				{query && !isSearching && (
					<span className="text-white/40 text-xs whitespace-nowrap">
						{resultCount === 1
							? t("rewind.result-singular")
							: t("rewind.results", { count: resultCount })}
					</span>
				)}
			</div>
		</div>
	);
}
