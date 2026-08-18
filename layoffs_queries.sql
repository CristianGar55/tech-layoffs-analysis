-- Layoffs Data Analysis Project
-- Dataset: Layoffs 2022 (Kaggle - swaptr/layoffs-2022)
-- Built in MySQL Workbench


-- ============================
-- SETUP
-- ============================

CREATE DATABASE layoffs_project;
USE layoffs_project;

-- Imported the raw CSV with the Table Data Import Wizard. Everything came
-- in as TEXT, including numbers and dates - fixed in the cleaning section
-- below. 4,494 rows in the raw `layoffs` table.


-- ============================
-- CLEANING
-- ============================

-- Working off a copy so the original import stays untouched
CREATE TABLE layoffs_staging AS
SELECT * FROM layoffs;


-- No unique ID column in this dataset, so checking for duplicates with
-- ROW_NUMBER() across every field. Anything with row_num > 1 is a dupe.
SELECT *,
    ROW_NUMBER() OVER (
        PARTITION BY company, location, industry, total_laid_off, 
                      percentage_laid_off, date, stage, country, funds_raised
        ORDER BY company
    ) AS row_num
FROM layoffs_staging;
-- None found.


-- 731 of 4,494 rows (~16%) have no total_laid_off and no percentage_laid_off.
-- These are real layoffs reported without an exact headcount, not junk rows.
-- Dropping them would mean losing a meaningful chunk of the data, so instead
-- they're flagged - they still count toward layoff frequency, and get
-- excluded specifically from anything that sums or averages headcounts.
ALTER TABLE layoffs_staging
ADD COLUMN has_confirmed_size TINYINT;

UPDATE layoffs_staging
SET has_confirmed_size = CASE
    WHEN (total_laid_off = '' OR total_laid_off IS NULL)
     AND (percentage_laid_off = '' OR percentage_laid_off IS NULL)
    THEN 0
    ELSE 1
END;
-- 731 unconfirmed, 3,763 confirmed.


-- A couple rows had no industry at all. Left as blank strings these can
-- behave oddly in GROUP BY, so relabeling instead of leaving them empty.
UPDATE layoffs_staging
SET industry = 'Unknown'
WHERE industry = '' OR industry IS NULL;


-- Trimming whitespace on text fields - extra spaces aren't always visible
-- in the result grid but can break GROUP BY / JOIN matching later.
UPDATE layoffs_staging
SET company = TRIM(company),
    location = TRIM(location),
    industry = TRIM(industry),
    stage = TRIM(stage),
    country = TRIM(country);


-- Converting numeric fields from text. Adding new columns rather than
-- converting in place, so each conversion can be checked before the
-- original text version is dropped.

ALTER TABLE layoffs_staging
ADD COLUMN total_laid_off_num INT;

-- Casting straight to UNSIGNED threw Error 1292 (Truncated incorrect
-- INTEGER value: '5500.0') - the source values carry a decimal point
-- even though they're whole numbers, and MySQL won't convert that
-- directly to UNSIGNED. Casting to DECIMAL first, then UNSIGNED, fixes it.
UPDATE layoffs_staging
SET total_laid_off_num = CASE
    WHEN total_laid_off = '' OR total_laid_off IS NULL THEN NULL
    ELSE CAST(CAST(total_laid_off AS DECIMAL(10,1)) AS UNSIGNED)
END;
-- 2,943 non-blank values converted successfully.


ALTER TABLE layoffs_staging
ADD COLUMN percentage_laid_off_num DECIMAL(5,2);

UPDATE layoffs_staging
SET percentage_laid_off_num = CASE
    WHEN percentage_laid_off = '' OR percentage_laid_off IS NULL THEN NULL
    ELSE CAST(percentage_laid_off AS DECIMAL(5,2))
END;
-- 3,967 values converted, no errors.


ALTER TABLE layoffs_staging
ADD COLUMN funds_raised_num DECIMAL(10,2);

UPDATE layoffs_staging
SET funds_raised_num = CASE
    WHEN funds_raised = '' OR funds_raised IS NULL THEN NULL
    ELSE CAST(funds_raised AS DECIMAL(10,2))
END;
-- 3,967 values converted.


-- Dates stored as text like '6/26/2026' (M/D/YYYY, no leading zeros).
ALTER TABLE layoffs_staging
ADD COLUMN date_clean DATE;

UPDATE layoffs_staging
SET date_clean = CASE
    WHEN date = '' OR date IS NULL THEN NULL
    ELSE STR_TO_DATE(date, '%m/%d/%Y')
END;
-- All 4,494 rows converted.

ALTER TABLE layoffs_staging
ADD COLUMN date_added_clean DATE;

UPDATE layoffs_staging
SET date_added_clean = CASE
    WHEN date_added = '' OR date_added IS NULL THEN NULL
    ELSE STR_TO_DATE(date_added, '%m/%d/%Y')
END;
-- All 4,494 rows converted.


-- Cleaning summary:
-- - no duplicates
-- - 2 blank industries relabeled 'Unknown'
-- - text fields trimmed
-- - 731 rows flagged as missing a confirmed layoff size (16% of the data)
-- - 3 text columns converted to numeric types
-- - 2 text columns converted to DATE


-- ============================
-- ANALYSIS
-- ============================

-- Top 10 largest confirmed layoffs
SELECT company, industry, country, total_laid_off_num, date_clean
FROM layoffs_staging
WHERE has_confirmed_size = 1 AND total_laid_off_num IS NOT NULL
ORDER BY total_laid_off_num DESC
LIMIT 10;


-- Industries with the highest total layoffs (over 5k)
SELECT industry, SUM(total_laid_off_num) AS total_layoffs, COUNT(*) AS num_events
FROM layoffs_staging
WHERE has_confirmed_size = 1
GROUP BY industry
HAVING SUM(total_laid_off_num) > 5000
ORDER BY total_layoffs DESC;


-- Severity tiers based on % of workforce cut. A value of 1.00 means
-- the company shut down entirely, not a partial layoff.
SELECT company, industry, percentage_laid_off_num,
    CASE 
        WHEN percentage_laid_off_num >= 0.5 THEN 'Severe'
        WHEN percentage_laid_off_num >= 0.2 THEN 'Moderate'
        WHEN percentage_laid_off_num IS NOT NULL THEN 'Minor'
        ELSE 'Unknown'
    END AS severity
FROM layoffs_staging
ORDER BY percentage_laid_off_num DESC
LIMIT 15;


-- Self-join to find companies with more than one layoff round, pairing
-- an earlier event with a later one
SELECT a.company, 
       a.date_clean AS first_layoff, 
       a.total_laid_off_num AS first_layoff_size,
       b.date_clean AS later_layoff, 
       b.total_laid_off_num AS later_layoff_size
FROM layoffs_staging a
JOIN layoffs_staging b 
    ON a.company = b.company 
    AND a.date_clean < b.date_clean
WHERE a.total_laid_off_num IS NOT NULL 
  AND b.total_laid_off_num IS NOT NULL
ORDER BY a.company, a.date_clean
LIMIT 15;


-- Companies whose layoffs exceeded their industry average, using a
-- correlated subquery to recompute the average per industry per row
SELECT company, industry, total_laid_off_num
FROM layoffs_staging l1
WHERE total_laid_off_num > (
    SELECT AVG(total_laid_off_num)
    FROM layoffs_staging l2
    WHERE l2.industry = l1.industry
      AND l2.total_laid_off_num IS NOT NULL
)
ORDER BY total_laid_off_num DESC
LIMIT 15;


-- Industry totals ranked with a CTE
WITH industry_totals AS (
    SELECT industry, SUM(total_laid_off_num) AS total_layoffs
    FROM layoffs_staging
    WHERE has_confirmed_size = 1
    GROUP BY industry
)
SELECT industry, total_layoffs,
    RANK() OVER (ORDER BY total_layoffs DESC) AS industry_rank
FROM industry_totals;


-- Running total of layoffs over time, with the previous event for comparison
SELECT 
    date_clean,
    total_laid_off_num,
    SUM(total_laid_off_num) OVER (ORDER BY date_clean) AS running_total,
    LAG(total_laid_off_num) OVER (ORDER BY date_clean) AS previous_layoff_event
FROM layoffs_staging
WHERE total_laid_off_num IS NOT NULL
ORDER BY date_clean
LIMIT 15;


-- ============================
-- DEEPER ANALYSIS: FUNDING & COMPANY STAGE
-- ============================
-- Went beyond "which industries got hit" to test whether funding level
-- or company stage actually predicts how severe a layoff was.
--
-- The funding tier bucket below had a bug on the first pass: any row
-- with a NULL funds_raised_num fell through to ELSE and got labeled
-- "Over $1B" - so companies with no funding data at all were getting
-- mixed in with actual billion-dollar companies, dragging that tier's
-- average down. Fixed with an explicit NULL check and a separate
-- 'Unknown' label.

-- Does more funding mean a smaller % of the workforce gets cut, or does
-- it just change the size of the absolute headcount cut?
SELECT 
    CASE 
        WHEN funds_raised_num IS NULL THEN 'Unknown'
        WHEN funds_raised_num < 10 THEN 'Under $10M'
        WHEN funds_raised_num < 100 THEN '$10M-$100M'
        WHEN funds_raised_num < 1000 THEN '$100M-$1B'
        ELSE 'Over $1B'
    END AS funding_tier,
    COUNT(*) AS num_events,
    ROUND(AVG(percentage_laid_off_num), 2) AS avg_pct_laid_off,
    ROUND(AVG(total_laid_off_num), 0) AS avg_headcount_laid_off
FROM layoffs_staging
GROUP BY funding_tier
ORDER BY MIN(funds_raised_num);

-- Avg % laid off drops as funding increases (Under $10M ~61%, Over $1B
-- ~17%), but avg headcount laid off is actually highest at Over $1B
-- (~715 people) - bigger companies cut a smaller share of their
-- workforce, but a much larger number of actual people.


-- Does company stage predict full shutdown risk?
-- Same NULL issue showed up here. The first version of this flag used
-- CASE WHEN percentage_laid_off_num = 1.00 THEN 1 ELSE 0 END, which
-- treated NULL as "not a shutdown" instead of excluding it, watering
-- down every stage's real rate. Fixed by passing NULL through instead.
SELECT 
    stage,
    COUNT(*) AS total_events,
    SUM(CASE WHEN percentage_laid_off_num = 1.00 THEN 1 ELSE 0 END) AS full_shutdowns,
    ROUND(100.0 * SUM(CASE WHEN percentage_laid_off_num = 1.00 THEN 1 ELSE 0 END) 
        / COUNT(percentage_laid_off_num), 1) AS shutdown_rate_pct
FROM layoffs_staging
WHERE stage IS NOT NULL AND stage != '' AND percentage_laid_off_num IS NOT NULL
GROUP BY stage
HAVING COUNT(*) >= 10
ORDER BY shutdown_rate_pct DESC;

-- Seed-stage layoffs were full shutdowns 71.2% of the time, vs. 23.6%
-- for Series A and under 3% for Post-IPO. At Seed stage, a "layoff" in
-- this dataset is mostly a company closing down, not trimming staff.


-- Before trusting that Seed number, checking it's not just an artifact
-- of one bad year (like the 2022-2023 downturn) rather than a pattern
-- tied to stage itself.
SELECT 
    stage,
    YEAR(date_clean) AS layoff_year,
    COUNT(*) AS num_events
FROM layoffs_staging
WHERE stage IN ('Seed', 'Post-IPO') AND date_clean IS NOT NULL
GROUP BY stage, layoff_year
ORDER BY stage, layoff_year;

-- Seed-stage shutdown events show up across nearly every year in the
-- dataset, not concentrated in a single downturn year - supports stage
-- being a real factor, not just a stand-in for timing.
--
-- Caveat worth keeping in mind: this measures outcomes among companies
-- that already had a layoff event, not a failure rate across all
-- Seed-stage companies. The dataset has no way to know how many Seed
-- companies never had a layoff at all, so this isn't a survival-rate claim.


-- Export used to feed the Excel dashboard - adds year/month/funding
-- tier/shutdown flag as pre-calculated columns so Excel doesn't need
-- to derive them with formulas
SELECT 
    company, 
    industry, 
    country, 
    stage,
    total_laid_off_num, 
    percentage_laid_off_num, 
    funds_raised_num,
    date_clean,
    YEAR(date_clean) AS layoff_year,
    MONTH(date_clean) AS layoff_month,
    CASE 
        WHEN funds_raised_num IS NULL THEN 'Unknown'
        WHEN funds_raised_num < 10 THEN 'Under $10M'
        WHEN funds_raised_num < 100 THEN '$10M-$100M'
        WHEN funds_raised_num < 1000 THEN '$100M-$1B'
        ELSE 'Over $1B'
    END AS funding_tier,
    CASE 
        WHEN percentage_laid_off_num IS NULL THEN NULL
        WHEN percentage_laid_off_num = 1.00 THEN 1 
        ELSE 0 
    END AS is_full_shutdown,
    has_confirmed_size
FROM layoffs_staging;
