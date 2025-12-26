import { chromium } from 'playwright';

async function checkConsoleErrors() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  
  const errors: string[] = [];
  page.on('console', msg => {
    if (msg.type() === 'error') {
      errors.push(msg.text());
    }
  });

  page.on('pageerror', err => {
    errors.push(err.message);
  });

  try {
    // Assuming the app is running on localhost:5173 (default vite port)
    await page.goto('http://localhost:5173');
    // Wait for some time to catch lazy loading errors
    await page.waitForTimeout(5000);
    
    if (errors.length > 0) {
      console.error('Frontend console errors found:');
      errors.forEach(err => console.error(`- ${err}`));
      process.exit(1);
    } else {
      console.log('No frontend console errors found.');
    }
  } catch (err) {
    console.error('Failed to connect to the app. Make sure it is running.');
    process.exit(1);
  } finally {
    await browser.close();
  }
}

checkConsoleErrors();
