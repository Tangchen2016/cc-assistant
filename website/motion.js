(() => {
  const preference = window.matchMedia('(prefers-reduced-motion: reduce)');
  const targets = document.querySelectorAll('.section-title, .feature-main, .feature-side article, .steps li, .download > div, .faq h2');
  let observer;
  function configure() {
    observer?.disconnect();
    targets.forEach((element) => element.classList.remove('enter-view'));
    if (preference.matches || !('IntersectionObserver' in window)) return;
    observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('enter-view');
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.12 });
    targets.forEach((element) => observer.observe(element));
  }
  configure();
  preference.addEventListener('change', configure);
})();
