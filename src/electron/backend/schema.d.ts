export interface Frame {
	id: number;
	createdAt: number;
	imgFilename: string | null;
	segmentID: number | null;
	videoPath: string | null;
	videoFrameIndex: number | null;
	collectionID: number | null;
	encodeStatus: number;
}

export interface EncodingTask {
	id: number;
	createdAt: number;
	status: number;
}

export interface EncodingTaskData {
	encodingTaskID: number;
	frame: number;
}

export interface AudioChunk {
	id: number;
	filename: string;
	startedAt: number;
	endedAt: number | null;
	duration: number | null;
	transcribeStatus: number;
}

export interface Transcription {
	id: number;
	audioChunkID: number;
	startOffset: number;
	endOffset: number;
	text: string;
	language: string | null;
}
