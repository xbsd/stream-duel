/ tests/test_fft.q: KissFFT through the KX C API (lib/kxfft.so) against known answers.
/ q tests/test_fft.q   (exits 0 when every check passes, 1 otherwise)
fails:0
check:{[name;ok] -1 (("FAIL ";"pass ") ok),name; if[not ok; fails+:1]}
fftmag:`:lib/kxfft 2:(`fftmag;2)
fftpeak:`:lib/kxfft 2:(`fftpeak;5)
PI:acos -1
/ naive DFT magnitude of one mean-removed window, for k = 0..n/2
dft:{[x] n:count x; x-:avg x; k:til 1+n div 2; j:til n;
  {[x;n;j;k] a:2*PI*k*j%n; sqrt[((x wsum cos a) xexp 2)+(x wsum sin a) xexp 2]%n}[x;n;j] each k}
x:(sin 2*PI*5*til[64]%64)+0.3*cos 2*PI*12*til[64]%64
check["fftmag matches a naive DFT"; 1e-9>max abs fftmag[x;64]-dft x]
two:x,reverse x
check["fftmag handles several windows at once"; 1e-9>max abs fftmag[two;64]-(dft x),dft reverse x]
fs:200f; n:512; t:til[n]%fs
tone:{[f;fs;n;seed] system"S ",string seed; (sin 2*PI*f*til[n]%fs)+0.5*-0.5+n?1f}
p:fftpeak[raze tone[;fs;n;42] each 11 17 23f;n;fs;5f;40f]
check["fftpeak finds 11, 17 and 23 Hz tones within 0.2 Hz"; all 0.2>abs p-11 17 23f]
check["fftpeak tells a 17 Hz rotor from a laden one at 15.64 Hz"; 1f<first abs fftpeak[tone[17;fs;n;1];n;fs;5f;40f]-fftpeak[tone[15.64;fs;n;1];n;fs;5f;40f]]
err:{[f;a] @[{x . y}f;a;{x}]}
check["a long list is a 'type error"; "type"~err[fftmag;(til 64;64)]]
check["a ragged batch is a 'length error"; "length"~err[fftmag;(65#1f;64)]]
check["a band holding no frequency bin is 0n"; null first fftpeak[x;64;64f;30.2f;30.6f]]
-1 $[fails;string[fails]," check(s) failed";"all fft checks passed"];
exit 0<fails
