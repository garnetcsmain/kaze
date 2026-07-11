import type { SearchResult } from "../hooks/useSearch";

interface SearchResultsProps {
	results: SearchResult[];
	visible: boolean;
	onJumpToResult: (result: SearchResult) => void;
}

function sanitizeSnippet(html: string): string {
	// Escape all HTML, then restore only <mark> and </mark> from FTS5
	return html
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/&lt;mark&gt;/g, "<mark>")
		.replace(/&lt;\/mark&gt;/g, "</mark>");
}

export function SearchResults({ results, visible, onJumpToResult }: SearchResultsProps) {
	if (!visible || results.length === 0) return null;

	return (
		<div className="absolute top-[72px] left-1/2 -translate-x-1/2 z-40 w-[500px] max-h-[50vh] overflow-y-auto rewind-scrollbar">
			<div className="rewind-glass-panel rounded-2xl py-1">
				{results.map((result) => (
					<button
						key={`${result.source}-${result.sourceID}`}
						className="w-full px-4 py-3 flex items-start gap-3 hover:bg-white/10 transition-colors text-left"
						onClick={() => onJumpToResult(result)}
					>
						{/* Source icon */}
						<span className="mt-0.5 shrink-0">
							{result.source === "ocr" ? (
								<svg
									className="w-4 h-4 text-white/40"
									fill="none"
									viewBox="0 0 24 24"
									stroke="currentColor"
									strokeWidth={2}
								>
									<path
										strokeLinecap="round"
										strokeLinejoin="round"
										d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
									/>
								</svg>
							) : (
								<svg
									className="w-4 h-4 text-white/40"
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
							)}
						</span>

						<div className="flex-1 min-w-0">
							<p
								className="text-white/80 text-sm leading-relaxed rewind-line-clamp-2"
								dangerouslySetInnerHTML={{ __html: sanitizeSnippet(result.snippet) }}
							/>
							{result.createdAt && (
								<p className="text-white/30 text-xs mt-1">
									{new Date(result.createdAt * 1000).toLocaleString()}
								</p>
							)}
						</div>
					</button>
				))}
			</div>
		</div>
	);
}
