-- Layoffs Data Analysis Project
-- Dataset: Layoffs 2022 (Kaggle - swaptr/layoffs-2022)
--  Tools: MySQL Workbench


-- ============================
-- SETUP
-- ============================

CREATE DATABASE layoffs_project;
USE layoffs_project;

-- Imported the raw CSV using the Table Data Import Wizard.
-- Everything came in as TEXT by default, even the numbers and dates -
-- that gets fixed later in the cleaning section.
-- Ended up with 4,494 rows in the raw `layoffs` table.

-- ============================
-- CLEANING
-- ============================

-- Working off a copy so I don't touch the original imported data
CREATE TABLE layoffs_staging AS
SELECT * FROM layoffs;


-- Checking for duplicates. No unique ID in this dataset, so I'm using
-- ROW_NUMBER() over every column - anything with row_num > 1 is a dupe.
SELECT *,
    ROW_NUMBER() OVER (
        PARTITION BY company, location, industry, total_laid_off, 
                      percentage_laid_off, date, stage, country, funds_raised
        ORDER BY company
    ) AS row_num
FROM layoffs_staging;

-- About 731 of the 4,494 rows (about 16%) don't have a total_laid_off
-- OR a percentage_laid_off - these are real layoffs that got reported
-- without an exact headcount. That's too much data to just throw away,
-- so instead of deleting these rows I'm flagging them. That way I can
-- still use them for "how often are layoffs happening" type questions,
-- and just exclude them when I need actual numbers (SUM, AVG, etc).
ALTER TABLE layoffs_staging
ADD COLUMN has_confirmed_size TINYINT;

UPDATE layoffs_staging
SET has_confirmed_size = CASE
    WHEN (total_laid_off = '' OR total_laid_off IS NULL)
     AND (percentage_laid_off = '' OR percentage_laid_off IS NULL)
    THEN 0
    ELSE 1
END;
-- 731 unconfirmed, 3,763 confirmed 


-- A couple rows had no industry listed at all. Leaving these blank felt
-- risky since blank strings can act weird in GROUP BY, so labeling them.
UPDATE layoffs_staging
SET industry = 'Unknown'
WHERE industry = '' OR industry IS NULL;


-- Trimming whitespace just in case - can't always see extra spaces in
-- the result grid, and they'll mess up GROUP BY / JOIN later if they're there.
UPDATE layoffs_staging
SET company = TRIM(company),
    location = TRIM(location),
    industry = TRIM(industry),
    stage = TRIM(stage),
    country = TRIM(country);


-- Now converting the numeric fields, since everything imported as text.
-- Adding new columns instead of converting in place, so I can double
-- check the conversion worked before deleting the original text version.

ALTER TABLE layoffs_staging
ADD COLUMN total_laid_off_num INT;

-- First attempt at this used CAST(... AS UNSIGNED) directly and it threw
-- Error 1292 (Truncated incorrect INTEGER value: '5500.0') - turns out
-- the source values have a decimal point even though they're whole
-- numbers, and MySQL doesn't like that when going straight to UNSIGNED.
-- Fix was casting to DECIMAL first, then UNSIGNED.
UPDATE layoffs_staging
SET total_laid_off_num = CASE
    WHEN total_laid_off = '' OR total_laid_off IS NULL THEN NULL
    ELSE CAST(CAST(total_laid_off AS DECIMAL(10,1)) AS UNSIGNED)
END;
-- All 2,943 non-blank values converted fine after that fix.


ALTER TABLE layoffs_staging
ADD COLUMN percentage_laid_off_num DECIMAL(5,2);

UPDATE layoffs_staging
SET percentage_laid_off_num = CASE
    WHEN percentage_laid_off = '' OR percentage_laid_off IS NULL THEN NULL
    ELSE CAST(percentage_laid_off AS DECIMAL(5,2))
END;
-- Converted cleanly, no errors - all 3,967 values came through.


ALTER TABLE layoffs_staging
ADD COLUMN funds_raised_num DECIMAL(10,2);

UPDATE layoffs_staging
SET funds_raised_num = CASE
    WHEN funds_raised = '' OR funds_raised IS NULL THEN NULL
    ELSE CAST(funds_raised AS DECIMAL(10,2))
END;
-- Also clean, all 3,967 values converted.


-- Dates were stored as text like '6/26/2026' (M/D/YYYY, no leading zeros),
-- Telling STR_TO_DATE exactly what format to expect.

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
-- Also all 4,494 rows converted.


-- ============================
-- ANALYSIS
-- ============================


-- Query 1: SELECT / WHERE / ORDER BY
-- Top 10 biggest confirmed layoffs
SELECT company, industry, country, total_laid_off_num, date_clean
FROM layoffs_staging
WHERE has_confirmed_size = 1 AND total_laid_off_num IS NOT NULL
ORDER BY total_laid_off_num DESC
LIMIT 10;


-- Query 2: GROUP BY / HAVING
-- Total confirmed layoffs by industry, only industries over 5,000 total
SELECT industry, SUM(total_laid_off_num) AS total_layoffs, COUNT(*) AS num_events
FROM layoffs_staging
WHERE has_confirmed_size = 1
GROUP BY industry
HAVING SUM(total_laid_off_num) > 5000
ORDER BY total_layoffs DESC;


-- Query 3: CASE WHEN
-- Labeling how severe each layoff was based on % of the company let go.
-- A value of 1.00 means the company shut down entirely.
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


-- Query 4: JOIN (self-join)
-- Companies with multiple layoff events, pairing earlier and later rounds
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


-- Query 5: Subquery (correlated)
-- Companies whose layoffs exceeded the average for their industry
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


-- Query 6: CTE (Common Table Expression)
-- Rank industries by total confirmed layoffs
WITH industry_totals AS (
    SELECT industry, SUM(total_laid_off_num) AS total_layoffs
    FROM layoffs_staging
    WHERE has_confirmed_size = 1
    GROUP BY industry
)
SELECT industry, total_layoffs,
    RANK() OVER (ORDER BY total_layoffs DESC) AS industry_rank
FROM industry_totals;


-- Query 7: Window Functions
-- Running total of layoffs over time + previous event comparison
SELECT 
    date_clean,
    total_laid_off_num,
    SUM(total_laid_off_num) OVER (ORDER BY date_clean) AS running_total,
    LAG(total_laid_off_num) OVER (ORDER BY date_clean) AS previous_layoff_event
FROM layoffs_staging
WHERE total_laid_off_num IS NOT NULL
ORDER BY date_clean
LIMIT 15;