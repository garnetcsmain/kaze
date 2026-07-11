import { useCallback, useEffect, useRef, useState } from "react";

export interface TranscriptionSegment {
	id: number;
	text: string;
	language: string | null;
	timestamp: number;
	endTimestamp: number;
	audioChunkID: number;
}

interface UseTranscriptionsOptions {
	port: number;
	apiKey: string;
	currentTimestamp: number | null;
	windowSeconds?: number;
	refetchThreshold?: number;
}

export function useTranscriptions({
	port,
	apiKey,
	currentTimestamp,
	windowSeconds = 300,
	refetchThreshold = 30
}: UseTranscriptionsOptions) {
	const [transcriptions, setTranscriptions] = useState<TranscriptionSegment[]>([]);
	const [isLoading, setIsLoading] = useState(false);
	const lastFetchCenter = useRef<number | null>(null);

	const fetchTranscriptions = useCallback(
		async (centerTimestamp: number) => {
			if (port < 0) return;

			setIsLoading(true);
			try {
				const from = centerTimestamp - windowSeconds;
				const to = centerTimestamp + windowSeconds;
				const url = new URL(`http://localhost:${port}/transcriptions`);
				url.searchParams.set("from", from.toString());
				url.searchParams.set("to", to.toString());

				const response = await fetch(url.toString(), {
					headers: { "x-api-key": apiKey }
				});
				const data = await response.json();
				setTranscriptions(data);
				lastFetchCenter.current = centerTimestamp;
			} catch (error) {
				console.error("Failed to fetch transcriptions:", error);
			} finally {
				setIsLoading(false);
			}
		},
		[port, apiKey, windowSeconds]
	);

	useEffect(() => {
		if (!currentTimestamp) return;

		const shouldRefetch =
			lastFetchCenter.current === null ||
			Math.abs(currentTimestamp - lastFetchCenter.current) > refetchThreshold;

		if (shouldRefetch) {
			fetchTranscriptions(currentTimestamp);
		}
	}, [currentTimestamp, refetchThreshold, fetchTranscriptions]);

	return { transcriptions, isLoading };
}
