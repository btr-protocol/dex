declare module 'snarkjs' {
  export const groth16: {
    fullProve(
      input: any,
      wasmFile: string,
      zkeyFile: string
    ): Promise<{
      proof: any;
      publicSignals: any;
    }>;

    verify(
      vKey: any,
      publicSignals: any,
      proof: any
    ): Promise<boolean>;
  };

  export const plonk: {
    fullProve(
      input: any,
      wasmFile: string,
      zkeyFile: string
    ): Promise<{
      proof: any;
      publicSignals: any;
    }>;

    verify(
      vKey: any,
      publicSignals: any,
      proof: any
    ): Promise<boolean>;
  };
}
