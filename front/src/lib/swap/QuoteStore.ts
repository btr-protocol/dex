/**
 * QuoteStore - Signal-based swap quote state management
 * Replaces 7 useState calls in useSwap.ts with centralized signal store
 */
import { signal, computed, batch } from '@preact/signals';
import type { Address } from '@sdk';

export interface SwapQuote {
  amountOut: bigint;
  amountIn: bigint;
  spreadBps: number;
  protoFee: bigint;
  lpFee: bigint;
  skewIn: number;
  skewOut: number;
  routeHops: Address[];
  hopAmounts: bigint[];
}

export class QuoteStore {
  // Quote state signals
  public quote = signal<SwapQuote | null>(null);
  public quoteLoading = signal(false);
  public quoteError = signal<string | null>(null);

  // Swap execution state signals
  public swapLoading = signal(false);
  public swapError = signal<string | null>(null);

  // Approval state signals
  public needsApproval = signal(false);
  public approveLoading = signal(false);

  // Computed: whether quote is valid and ready
  public isQuoteValid = computed(() =>
    this.quote.value !== null &&
    this.quoteError.value === null &&
    !this.quoteLoading.value
  );

  // Computed: whether ready to swap
  public canSwap = computed(() =>
    this.isQuoteValid.value &&
    !this.needsApproval.value &&
    !this.swapLoading.value
  );

  // Computed: whether ready to approve
  public canApprove = computed(() =>
    this.isQuoteValid.value &&
    this.needsApproval.value &&
    !this.approveLoading.value
  );

  /**
   * Batch update quote state
   * Prevents multiple re-renders by updating all related state together
   */
  public setQuoteSuccess(quote: SwapQuote) {
    batch(() => {
      this.quote.value = quote;
      this.quoteError.value = null;
      this.quoteLoading.value = false;
    });
  }

  /**
   * Batch update quote error state
   */
  public setQuoteError(error: string) {
    batch(() => {
      this.quote.value = null;
      this.quoteError.value = error;
      this.quoteLoading.value = false;
    });
  }

  /**
   * Start quote loading
   */
  public startQuoteLoading() {
    batch(() => {
      this.quoteLoading.value = true;
      this.quoteError.value = null;
    });
  }

  /**
   * Clear quote state
   */
  public clearQuote() {
    batch(() => {
      this.quote.value = null;
      this.quoteError.value = null;
      this.quoteLoading.value = false;
    });
  }

  /**
   * Batch update swap state
   */
  public setSwapError(error: string) {
    batch(() => {
      this.swapError.value = error;
      this.swapLoading.value = false;
    });
  }

  /**
   * Start swap execution
   */
  public startSwapExecution() {
    batch(() => {
      this.swapLoading.value = true;
      this.swapError.value = null;
    });
  }

  /**
   * Complete swap execution
   */
  public completeSwapExecution() {
    this.swapLoading.value = false;
  }

  /**
   * Update approval requirement
   */
  public setNeedsApproval(needs: boolean) {
    this.needsApproval.value = needs;
  }

  /**
   * Start approval transaction
   */
  public startApproval() {
    this.approveLoading.value = true;
  }

  /**
   * Complete approval transaction
   */
  public completeApproval(success: boolean) {
    batch(() => {
      this.approveLoading.value = false;
      if (success) {
        this.needsApproval.value = false;
      }
    });
  }

  /**
   * Reset all state (e.g., on wallet disconnect)
   */
  public reset() {
    batch(() => {
      this.quote.value = null;
      this.quoteLoading.value = false;
      this.quoteError.value = null;
      this.swapLoading.value = false;
      this.swapError.value = null;
      this.needsApproval.value = false;
      this.approveLoading.value = false;
    });
  }
}

// Create singleton instance
export const quoteStore = new QuoteStore();
