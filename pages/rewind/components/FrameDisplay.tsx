interface FrameDisplayProps {
	currentUrl: string | null;
	fallbackUrl: string | null;
	isLoading: boolean;
}

export function FrameDisplay({ currentUrl, fallbackUrl, isLoading }: FrameDisplayProps) {
	const displayUrl = currentUrl || fallbackUrl || "";

	return (
		<>
			{/* Blurred background */}
			<img
				src={displayUrl}
				alt=""
				className="w-full h-full object-cover absolute inset-0 blur-lg"
			/>

			{/* Main frame with fade transition */}
			<img
				src={displayUrl}
				alt="Current frame"
				className={`w-full h-full object-contain absolute inset-0 transition-opacity duration-150 ${
					currentUrl ? "opacity-100" : "opacity-90"
				}`}
			/>

			{/* Loading spinner */}
			{isLoading && !currentUrl && (
				<div className="absolute inset-0 flex items-center justify-center z-10">
					<div className="rewind-spinner" />
				</div>
			)}
		</>
	);
}
