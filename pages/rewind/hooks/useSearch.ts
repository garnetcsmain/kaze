import { useCallback, useEffect, useRef, useState } from "react";

export interface SearchResult {
	source: string;
	sourceID: number;
	frameID: number | null;
	audioChunkID: number | null;
	snippet: string;
	createdAt: number | null;
}

interface UseSearchOptions {
	port: number;
	apiKey: string;
	debounceMs?: number;
}

export function useSearch({ port, apiKey, debounceMs = 300 }: UseSearchOptions) {
	const [query, setQuery] = useState("");
	const [results, setResults] = useState<SearchResult[]>([]);
	const [isSearching, setIsSearching] = useState(false);
	const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	const performSearch = useCallback(
		async (q: string) => {
			if (port < 0 || !q.trim()) {
				setResults([]);
				setIsSearching(false);
				return;
			}

			setIsSearching(true);
			try {
				const url = new URL(`http://localhost:${port}/search`);
				url.searchParams.set("q", q);
				url.searchParams.set("limit", "20");
				const response = await fetch(url.toString(), {
					headers: { "x-api-key": apiKey }
				});
				const data = await response.json();
				setResults(data);
			} catch (error) {
				console.error("Search failed:", error);
				setResults([]);
			} finally {
				setIsSearching(false);
			}
		},
		[port, apiKey]
	);

	useEffect(() => {
		if (debounceRef.current) clearTimeout(debounceRef.current);

		if (!query.trim()) {
			setResults([]);
			return;
		}

		debounceRef.current = setTimeout(() => {
			performSearch(query);
		}, debounceMs);

		return () => {
			if (debounceRef.current) clearTimeout(debounceRef.current);
		};
	}, [query, performSearch, debounceMs]);

	return { query, setQuery, results, isSearching };
}
